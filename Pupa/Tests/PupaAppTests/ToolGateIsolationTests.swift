import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests that tool-gate activation is confined to the session that made it.
///
/// [ToolGatingTests] covers *what* a gate unlocks; this suite covers *who*
/// sees the unlock. A `ToolGateState` is built per session — one per
/// `(scope, threadId)` ChatViewModel, one per sub-run — and captured weakly
/// by the `get_tools_<kind>` handlers registered alongside it. Nothing is
/// global, so an activation must never reach a sibling thread, a sibling
/// myApp, or a concurrently running turn.
@MainActor
@Suite("Tool gate isolation across threads and concurrent runs")
struct ToolGateIsolationTests {

    init() { TestStorage.activate() }

    /// Two myApps of the tracker type, each carrying a tracker *and* a
    /// calendar component so both kind gates are advertised in both.
    private func makeStore(count: Int = 2) -> (store: MyAppStore, ids: [UUID]) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApps = (0..<count).map { i in
            MyApp(name: "MyApp \(i)", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        }
        let store = MyAppStore(initial: (myApps, myApps[0].id))
        for myApp in myApps {
            store.addComponent(kind: "tracker", name: "T", iconSystemName: "book", myAppId: myApp.id)
            store.addComponent(kind: "calendar", name: "C", iconSystemName: "calendar", myAppId: myApp.id)
        }
        return (store, myApps.map(\.id))
    }

    private func makeCoordinator(store: MyAppStore) -> ChatSessionCoordinator {
        ChatSessionCoordinator(
            store: store,
            memory: MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pupa-tests-\(UUID().uuidString)")),
            settings: SettingsStore(backendURL: URL(string: "http://localhost:65535/")!)
        )
    }

    private func callGate(_ name: String, on vm: ChatViewModel) async throws {
        let tool = try #require(vm.registry.resolve(name))
        _ = try await tool.handler(.object([:]))
    }

    // MARK: - Mechanism

    /// The property every other case rests on: each handler closure captures
    /// one specific `ToolGateState`, so the same gate tools registered on a
    /// second registry cannot cross-activate the first. This is exactly what
    /// isolates the coordinator's sub-runs (`runOneShot`, `runSubagent`, the
    /// Slack invoke path), which build a fresh registry + gate per call.
    @Test("Gate handlers mutate only the ToolGateState they were registered with")
    func gateHandlerWritesOnlyItsOwnState() async throws {
        MyAppTypeRegistry.shared.registerBuiltins()
        let type = MyAppType.tracker
        let gateA = ToolGateState()
        let gateB = ToolGateState()
        let registryA = ToolRegistry()
        let registryB = ToolRegistry()
        AppTools.registerToolGates(on: registryA, myAppType: type, toolGateState: gateA)
        AppTools.registerToolGates(on: registryB, myAppType: type, toolGateState: gateB)
        AppTools.registerNotificationTools(on: registryA, coordinator: .shared, toolGateState: gateA)
        AppTools.registerNotificationTools(on: registryB, coordinator: .shared, toolGateState: gateB)

        _ = try await #require(registryA.resolve("get_tools_tracker")).handler(.object([:]))
        _ = try await #require(registryA.resolve("get_tools_memories")).handler(.object([:]))
        _ = try await #require(registryA.resolve("get_tools_notifications")).handler(.object([:]))

        #expect(gateA.isActivated(kind: "tracker"))
        #expect(gateA.isMemoriesActivated)
        #expect(gateA.isNotificationsActivated)
        #expect(!gateB.isActivated(kind: "tracker"))
        #expect(!gateB.isMemoriesActivated)
        #expect(!gateB.isNotificationsActivated)
    }

    /// Two independent states never share activations, in either direction.
    @Test("Activations on one ToolGateState leave a second instance untouched")
    func statesAreIndependent() {
        let (store, ids) = makeStore(count: 1)
        let a = ToolGateState()
        let b = ToolGateState()

        a.activate(kind: "tracker")
        b.activate(kind: "calendar")

        let allowedA = ChatViewModel.allowedToolNames(scope: .myApp(ids[0]), store: store, toolGateState: a)
        let allowedB = ChatViewModel.allowedToolNames(scope: .myApp(ids[0]), store: store, toolGateState: b)

        #expect(allowedA.contains("renderTracker"))
        #expect(!allowedA.contains("renderCalendar"))
        #expect(allowedA.contains("get_tools_calendar"))
        #expect(allowedB.contains("renderCalendar"))
        #expect(!allowedB.contains("renderTracker"))
        #expect(allowedB.contains("get_tools_tracker"))
    }

    // MARK: - Per-thread

    /// Same myApp, two conversations. The coordinator keys sessions on
    /// `(scope, threadId)`, so thread 2 must still see the gate after thread 1
    /// unlocked the tracker tools.
    @Test("Two threads in the same myApp scope have independent gates")
    func gatesAreIsolatedPerThread() async throws {
        let (store, ids) = makeStore(count: 1)
        let coord = makeCoordinator(store: store)
        let t1 = coord.session(for: .myApp(ids[0]), threadId: "thread-1")
        let t2 = coord.session(for: .myApp(ids[0]), threadId: "thread-2")
        #expect(t1 !== t2)

        try await callGate("get_tools_tracker", on: t1)

        #expect(t1.currentAllowedToolNames.contains("renderTracker"))
        #expect(!t1.currentAllowedToolNames.contains("get_tools_tracker"))
        #expect(!t2.currentAllowedToolNames.contains("renderTracker"))
        #expect(t2.currentAllowedToolNames.contains("get_tools_tracker"))
    }

    /// A "New session" starts a new thread, hence a new session key, hence a
    /// fresh gate — activations must not survive it.
    @Test("A new thread on the same scope starts from a closed gate")
    func newThreadStartsClosed() async throws {
        let (store, ids) = makeStore(count: 1)
        let coord = makeCoordinator(store: store)
        let first = coord.session(for: .myApp(ids[0]), threadId: store.currentThreadId(for: .myApp(ids[0])))
        try await callGate("get_tools_memories", on: first)
        #expect(first.currentAllowedToolNames.contains("lsMemories"))

        first.newThread()
        let next = coord.session(for: .myApp(ids[0]))

        #expect(next !== first)
        #expect(!next.currentAllowedToolNames.contains("lsMemories"))
        #expect(next.currentAllowedToolNames.contains("get_tools_memories"))
    }

    // MARK: - Cross-scope

    @Test("A gate opened in one myApp stays shut in a sibling myApp")
    func gatesAreIsolatedPerMyApp() async throws {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let a = coord.session(for: .myApp(ids[0]))
        let b = coord.session(for: .myApp(ids[1]))

        try await callGate("get_tools_tracker", on: a)

        #expect(a.currentAllowedToolNames.contains("renderTracker"))
        #expect(!b.currentAllowedToolNames.contains("renderTracker"))
        #expect(b.currentAllowedToolNames.contains("get_tools_tracker"))
    }

    /// The memory-filesystem and notification gates are per session too.
    /// (The orchestrator's memory FS is ungated by design — only its
    /// notifications sit behind a gate.)
    @Test("Memories and notifications unlocks stay in the session that made them")
    func memoryAndNotificationGatesAreScoped() async throws {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let a = coord.session(for: .myApp(ids[0]))
        let b = coord.session(for: .myApp(ids[1]))
        let orchestrator = coord.session(for: .memory)

        try await callGate("get_tools_memories", on: a)
        try await callGate("get_tools_notifications", on: orchestrator)

        #expect(a.currentAllowedToolNames.contains("writeMemoryFile"))
        #expect(!b.currentAllowedToolNames.contains("writeMemoryFile"))
        #expect(b.currentAllowedToolNames.contains("get_tools_memories"))

        #expect(orchestrator.currentAllowedToolNames.contains("sendNotification"))
        #expect(!a.currentAllowedToolNames.contains("sendNotification"))
        #expect(a.currentAllowedToolNames.contains("get_tools_notifications"))
    }

    // MARK: - Concurrency

    /// Two sessions unlocking different kinds at the same time: each ends up
    /// with its own kind only. Guards against a shared or last-writer-wins
    /// gate store being introduced later.
    @Test("Concurrent gate activations in two sessions do not mix")
    func concurrentActivationsDoNotMix() async throws {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let a = coord.session(for: .myApp(ids[0]))
        let b = coord.session(for: .myApp(ids[1]))

        async let unlockA: Void = callGate("get_tools_tracker", on: a)
        async let unlockB: Void = callGate("get_tools_calendar", on: b)
        _ = try await (unlockA, unlockB)

        let allowedA = a.currentAllowedToolNames
        let allowedB = b.currentAllowedToolNames

        #expect(allowedA.contains("renderTracker"))
        #expect(!allowedA.contains("renderCalendar"))
        #expect(allowedB.contains("renderCalendar"))
        #expect(!allowedB.contains("renderTracker"))
    }

    /// Many interleaved activations across many threads of the same myApp:
    /// each thread must end holding exactly the kind it asked for.
    @Test("Interleaved activations across many threads each stay put")
    func interleavedActivationsStayPut() async throws {
        let (store, ids) = makeStore(count: 1)
        let coord = makeCoordinator(store: store)
        let kinds = ["tracker", "calendar", "tracker", "calendar", "tracker", "calendar"]
        let sessions = kinds.indices.map { coord.session(for: .myApp(ids[0]), threadId: "t\($0)") }

        var tasks: [Task<Void, Never>] = []
        for (i, kind) in kinds.enumerated() {
            let vm = sessions[i]
            let gate = "get_tools_\(kind)"
            tasks.append(Task { @MainActor in
                guard let tool = vm.registry.resolve(gate) else { return }
                _ = try? await tool.handler(.object([:]))
            })
        }
        for task in tasks { await task.value }

        for (i, kind) in kinds.enumerated() {
            let allowed = sessions[i].currentAllowedToolNames
            let other = kind == "tracker" ? "calendar" : "tracker"
            #expect(allowed.contains(kind == "tracker" ? "renderTracker" : "renderCalendar"))
            #expect(!allowed.contains(kind == "tracker" ? "renderCalendar" : "renderTracker"))
            #expect(allowed.contains("get_tools_\(other)"))
        }
    }
}
