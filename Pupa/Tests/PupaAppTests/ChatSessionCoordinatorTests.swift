import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for `ChatSessionCoordinator` — the registry that owns one
/// `ChatViewModel` per `ChatScope` and gives the app its concurrent
/// per-myApp chat behaviour (issue #17).
@MainActor
@Suite("ChatSessionCoordinator")
struct ChatSessionCoordinatorTests {

    /// `bootstrapMemories()` writes AGENTS.md under `PupaStorage.activeRoot`.
    init() { TestStorage.activate() }

    private func makeStore(spaceCount: Int = 2) -> (store: MyAppStore, ids: [UUID]) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApps = (0..<spaceCount).map { i in
            MyApp(name: "MyApp \(i)", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        }
        let store = MyAppStore(initial: (myApps, myApps[0].id))
        return (store, myApps.map(\.id))
    }

    private func makeCoordinator(store: MyAppStore) -> ChatSessionCoordinator {
        ChatSessionCoordinator(
            store: store,
            memory: MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pupa-tests-\(UUID().uuidString)")),
            settings: SettingsStore(backendURL: URL(string: "http://localhost:65535/")!)
        )
    }

    @Test("session(for:) caches per scope — same key returns same instance")
    func cachesPerScope() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)

        let first = coord.session(for: .myApp(ids[0]))
        let second = coord.session(for: .myApp(ids[0]))

        #expect(first === second)
    }

    @Test("Different myApp scopes return distinct ChatViewModel instances")
    func distinctPerSpace() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)

        let a = coord.session(for: .myApp(ids[0]))
        let b = coord.session(for: .myApp(ids[1]))

        #expect(a !== b)
        #expect(a.pinnedScope == .myApp(ids[0]))
        #expect(b.pinnedScope == .myApp(ids[1]))
    }

    @Test("Memory scope is independent from any myApp scope")
    func memoryIsSeparate() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)

        let mem = coord.session(for: .memory)
        let a = coord.session(for: .myApp(ids[0]))

        #expect(mem !== a)
        #expect(mem.pinnedScope == .memory)
    }

    @Test("discardSession drops the cached session — next session(for:) builds a fresh one")
    func discardEvicts() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)

        let original = coord.session(for: .myApp(ids[0]))
        coord.discardSession(for: .myApp(ids[0]))
        let rebuilt = coord.session(for: .myApp(ids[0]))

        #expect(original !== rebuilt)
    }

    @Test("status/aggregateStatus are .idle when no live session exists or the session is fresh")
    func statusIdleByDefault() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let tid = store.currentThreadId(for: .myApp(ids[0]))

        // No session opened yet for this scope/thread.
        #expect(coord.status(for: .myApp(ids[0]), threadId: tid) == .idle)
        #expect(coord.aggregateStatus(for: .myApp(ids[0])) == .idle)

        // A freshly-built session (never streamed) is still idle.
        _ = coord.session(for: .myApp(ids[0]), threadId: tid)
        #expect(coord.status(for: .myApp(ids[0]), threadId: tid) == .idle)
        #expect(coord.aggregateStatus(for: .myApp(ids[0])) == .idle)
        // A different scope with no sessions stays idle too.
        #expect(coord.aggregateStatus(for: .myApp(ids[1])) == .idle)
    }

    @Test("busyMyApps starts empty and discardSession is safe to call on a never-streamed session")
    func busySpacesEmptyAndDiscardSafe() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)

        #expect(coord.busyMyApps.isEmpty)
        _ = coord.session(for: .myApp(ids[0]))
        #expect(coord.busyMyApps.isEmpty)  // creating a session does not mark it busy
        coord.discardSession(for: .myApp(ids[0]))  // no crash on an idle session
        #expect(coord.busyMyApps.isEmpty)
    }

    /// Direct refcount drive — pins the contract `busyMyApps` exposes a myApp
    /// while *any* claim against it is outstanding. This is the layer the
    /// orchestrator sub-run relies on so that an in-flight `invokeMyAppAgent`
    /// lights up the sidebar spinner the same way the user's own chat would,
    /// AND so a user-stream ending mid-sub-run doesn't prematurely clear it.
    @Test("busyMyApps is refcounted — multiple claims on the same myApp stack and unwind correctly")
    func busySpaces_refcountsAcrossConcurrentClaims() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let target = ids[0]

        #expect(coord.busyMyApps.isEmpty)

        // Simulate the user's own chat starting a turn in `target`.
        coord.incrementBusy(target)
        #expect(coord.busyMyApps == [target])

        // Now an orchestrator sub-run kicks off against the same myApp.
        coord.incrementBusy(target)
        #expect(coord.busyMyApps == [target], "Still busy — both claims outstanding")

        // The user's chat finishes first. Spinner must stay lit because the
        // sub-run is still running.
        coord.decrementBusy(target)
        #expect(
            coord.busyMyApps == [target],
            "User chat ended but sub-run still in flight — spinner must remain"
        )

        // Sub-run finishes. Now the myApp is truly idle.
        coord.decrementBusy(target)
        #expect(coord.busyMyApps.isEmpty)
    }

    @Test("Decrementing past zero is a no-op and does not flip busyMyApps into a bad state")
    func busySpaces_decrementPastZeroIsNoOp() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let target = ids[0]

        coord.decrementBusy(target)  // never incremented — must not crash or go negative
        #expect(coord.busyMyApps.isEmpty)

        coord.incrementBusy(target)
        coord.decrementBusy(target)
        coord.decrementBusy(target)  // one extra decrement
        #expect(coord.busyMyApps.isEmpty, "Refcount must clamp at zero")

        // After the over-decrement, a fresh claim still works.
        coord.incrementBusy(target)
        #expect(coord.busyMyApps == [target])
    }

    /// End-to-end behavioural test for the orchestrator's sub-run busy-flag
    /// wiring. The coordinator runs against an unreachable backend with a
    /// **fast-timeout** `URLSession` so the sub-run fails quickly; what we
    /// pin is that the target myApp appears in `busyMyApps` while the sub-run
    /// is in flight and is gone again once it settles — i.e. `runOneShot`'s
    /// `incrementBusy` + `defer { decrementBusy(...) }` actually fire.
    @Test("runOneShot lights up busyMyApps for the target myApp while in flight, clears on exit")
    func runOneShot_marksTargetBusyThenClearsOnExit() async throws {
        let (store, ids) = makeStore()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.3
        cfg.timeoutIntervalForResource = 0.3
        let coord = ChatSessionCoordinator(
            store: store,
            memory: MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pupa-tests-\(UUID().uuidString)")),
            // TEST-NET-1 (RFC 5737) is blackholed: connect() hangs until the
            // 0.3s timeout rather than RST-ing instantly. That keeps the run
            // in-flight long enough for the poll below to observe busy — a
            // refused port (e.g. 127.0.0.1:1) fails before the first sample.
            settings: SettingsStore(backendURL: URL(string: "http://192.0.2.1/")!),
            urlSession: URLSession(configuration: cfg)
        )
        let target = ids[0]

        #expect(coord.busyMyApps.isEmpty)

        let runTask = Task<Void, Never> {
            _ = try? await coord.runOneShot(
                myAppId: target, prompt: "ping", caller: .session(.orchestrator)
            )
        }

        // Wait for runOneShot's incrementBusy to land. The increment is
        // synchronous on MainActor before the HTTP POST is awaited, so this
        // typically clears in the first yield — but allow a small grace
        // window so the test stays robust under scheduler jitter.
        for _ in 0..<50 {
            if coord.busyMyApps.contains(target) { break }
            try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
        }
        #expect(
            coord.busyMyApps.contains(target),
            "Sub-run must mark its target myApp busy while in flight — sidebar spinner depends on this."
        )

        // Wait for the run to settle (connect timeout → throw → defer fires).
        await runTask.value
        #expect(coord.busyMyApps.isEmpty, "busyMyApps must clear after the sub-run exits.")
    }

    // MARK: - Delegation stats wiring

    /// Throwaway defaults domain so stats tests never touch `.standard`.
    private func freshDefaults() -> UserDefaults {
        let name = "agentstats-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Coordinator pointed at a blackholed backend with a fast connect
    /// timeout: a sub-run enters the gate synchronously, then fails at the
    /// first POST. Enough to observe everything that happens before the wire.
    private func makeStatsCoordinator(
        store: MyAppStore,
        stats: AgentStatsStore
    ) -> ChatSessionCoordinator {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.3
        cfg.timeoutIntervalForResource = 0.3
        return ChatSessionCoordinator(
            store: store,
            memory: MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pupa-tests-\(UUID().uuidString)")),
            settings: SettingsStore(backendURL: URL(string: "http://192.0.2.1/")!),
            agentStats: stats,
            urlSession: URLSession(configuration: cfg)
        )
    }

    @Test("runOneShot from the orchestrator chat panel records the delegation")
    func runOneShotRecordsSessionDelegation() async {
        let (store, ids) = makeStore()
        let stats = AgentStatsStore(defaults: freshDefaults())
        let coord = makeStatsCoordinator(store: store, stats: stats)

        _ = try? await coord.runOneShot(
            myAppId: ids[0], prompt: "ping", caller: .session(.orchestrator)
        )

        #expect(
            stats.stat(for: "orchestrator").count(AgentStatsStore.delegationsMade) == 1,
            "The chat panel is ungated, but its delegation must still be attributed."
        )
        #expect(
            stats.stat(for: ids[0].uuidString).count(AgentStatsStore.invocationsReceived) == 1
        )
    }

    /// The regression test proper: drives the REAL `invokeMyAppAgent` handler
    /// off the REAL orchestrator registry, so the caller context is chosen by
    /// production code, not by the test. Nothing covered this path before —
    /// which is why first-level delegations went uncounted.
    @Test("invokeMyAppAgent from the orchestrator registry counts both sides")
    func orchestratorToolCountsDelegation() async throws {
        let (store, ids) = makeStore()
        let stats = AgentStatsStore(defaults: freshDefaults())
        let coord = makeStatsCoordinator(store: store, stats: stats)

        let tool = try #require(coord.session(for: .memory).registry.resolve("invokeMyAppAgent"))
        _ = try? await tool.handler(.object([
            "myAppId": .string(ids[0].uuidString),
            "prompt": .string("hi"),
        ]))

        #expect(stats.stat(for: "orchestrator").count(AgentStatsStore.delegationsMade) == 1)
        #expect(stats.stat(for: ids[0].uuidString).count(AgentStatsStore.invocationsReceived) == 1)
    }

    /// Same, one level down: a MyApp's own chat panel delegating to one of its
    /// `pupa/agents/<slug>` subagents.
    @Test("invoke_agent from a myApp chat panel counts both sides")
    func myAppToolCountsSubagentDelegation() async throws {
        let (store, ids) = makeStore()
        let stats = AgentStatsStore(defaults: freshDefaults())
        let coord = makeStatsCoordinator(store: store, stats: stats)
        // `runSubagent` throws `.notFound` before ever reaching the gate, so
        // the subagent has to exist on disk.
        let appMemory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: ids[0]))
        _ = try AgentStore(memory: appMemory).createAgent(name: "scout", description: "recon")

        let tool = try #require(coord.session(for: .myApp(ids[0])).registry.resolve("invoke_agent"))
        _ = try? await tool.handler(.object([
            "name": .string("scout"),
            "prompt": .string("hi"),
        ]))

        #expect(stats.stat(for: ids[0].uuidString).count(AgentStatsStore.delegationsMade) == 1)
        #expect(
            stats.stat(for: "subagent:\(ids[0].uuidString):scout")
                .count(AgentStatsStore.invocationsReceived) == 1
        )
    }
}
