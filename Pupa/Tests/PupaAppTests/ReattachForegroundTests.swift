import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Foreground-recovery wiring for resumable SSE (pupa#103) at the app-target
/// layer — the gating + fan-out that sits on top of AGUIKit's `reattach()`.
///
/// The AGUIKit `ReattachTests` pin the wire (seq parsing, `after_seq`, replay
/// dispatch, drop retry). These pin the client's decisions:
///   - `ChatViewModel.reattachIfNeeded` only recovers a session whose last turn
///     actually errored and whose stream is dead.
///   - `ChatSessionCoordinator.reattachAllAfterForeground` fans out to every
///     live session, so several backgrounded chats each recover on their own.
///
/// Deterministic without a mock transport: a refused port (`localhost:65535`)
/// fails the POST fast → the turn surfaces as `lastError`; a blackholed address
/// (`192.0.2.1`, TEST-NET-1) hangs connect → the stream stays live. Recovery
/// itself makes no network call here — no replay cursor was ever set, so
/// `reattach()` short-circuits to `.completed`.
@MainActor
@Suite("Resumable SSE foreground reattach")
struct ReattachForegroundTests {

    private let refused = URL(string: "http://localhost:65535/")!

    private func makeMemory() -> MemoryStore {
        MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pupa-tests-\(UUID().uuidString)"))
    }

    private func makeStore(_ count: Int = 2) -> (store: MyAppStore, ids: [UUID]) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let apps = (0..<count).map {
            MyApp(name: "MyApp \($0)", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        }
        return (MyAppStore(initial: (apps, apps[0].id)), apps.map(\.id))
    }

    private func makeVM(
        store: MyAppStore,
        scope: ChatScope,
        backend: URL,
        session: URLSession = .shared
    ) -> ChatViewModel {
        ChatViewModel(
            store: store,
            memory: makeMemory(),
            settings: SettingsStore(backendURL: backend),
            registry: ToolRegistry(),
            scope: scope,
            threadId: store.currentThreadId(for: scope),
            urlSession: session,
            toolGateState: ToolGateState()
        )
    }

    private func makeCoordinator(store: MyAppStore, backend: URL) -> ChatSessionCoordinator {
        ChatSessionCoordinator(store: store, memory: makeMemory(), settings: SettingsStore(backendURL: backend))
    }

    /// Poll a MainActor condition up to `ms` milliseconds.
    private func awaitUntil(_ ms: Int = 2000, _ cond: @escaping () -> Bool) async -> Bool {
        for _ in 0..<(ms / 10) {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    // MARK: - reattachIfNeeded gating

    @Test("reattachIfNeeded is a no-op on a fresh session — no error, no stream")
    func reattach_freshVM_noOp() {
        let (store, ids) = makeStore(1)
        let vm = makeVM(store: store, scope: .myApp(ids[0]), backend: refused)

        #expect(vm.lastError == nil)
        #expect(vm.isStreaming == false)

        vm.reattachIfNeeded()  // both guards fail → nothing happens

        #expect(vm.isStreaming == false)
        #expect(vm.lastError == nil)
    }

    @Test("reattachIfNeeded on a session whose last turn errored clears the error and drives recovery")
    func reattach_afterFailedSend_fires() async {
        let (store, ids) = makeStore(1)
        let vm = makeVM(store: store, scope: .myApp(ids[0]), backend: refused)

        vm.send("hi")  // POST to a refused port → turn surfaces as lastError
        let armed = await awaitUntil { vm.lastError != nil && vm.isStreaming == false }
        #expect(armed, "a send to an unreachable backend should surface lastError")

        vm.reattachIfNeeded()
        // Fired: lastError cleared synchronously; recovery finds no replay
        // cursor so it settles straight back to not-streaming.
        #expect(vm.lastError == nil)
        #expect(await awaitUntil { vm.isStreaming == false })
    }

    @Test("reattachIfNeeded does not disturb a session whose stream is still live")
    func reattach_whileStreaming_noOp() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.0
        cfg.timeoutIntervalForResource = 1.0
        let (store, ids) = makeStore(1)
        // 192.0.2.1 blackholes connect → the POST hangs, keeping the stream live.
        let vm = makeVM(
            store: store, scope: .myApp(ids[0]),
            backend: URL(string: "http://192.0.2.1/")!,
            session: URLSession(configuration: cfg)
        )

        vm.send("hi")
        #expect(await awaitUntil(500) { vm.isStreaming }, "send should flip streaming on")
        #expect(vm.lastError == nil)

        vm.reattachIfNeeded()  // streamTask != nil → must skip
        #expect(vm.isStreaming, "reattach must not interrupt a live stream")
        #expect(vm.lastError == nil)

        vm.cancel()  // tidy the hanging task
    }

    // MARK: - Coordinator fan-out across sessions

    @Test("reattachAllAfterForeground fans out to every session; each decides independently")
    func coordinator_fanOut() async {
        let (store, ids) = makeStore(2)
        let coord = makeCoordinator(store: store, backend: refused)
        let a = coord.session(for: .myApp(ids[0]))
        let b = coord.session(for: .myApp(ids[1]))  // fresh — never sent

        a.send("hi")
        #expect(await awaitUntil { a.lastError != nil && a.isStreaming == false })
        #expect(b.lastError == nil)

        coord.reattachAllAfterForeground()

        // A errored → recovery fired (error cleared). B was clean → untouched.
        #expect(a.lastError == nil)
        #expect(b.lastError == nil)
        #expect(b.isStreaming == false)
    }

    @Test("Multiple in-flight chats each recover independently on foreground")
    func coordinator_multipleChats() async {
        let (store, ids) = makeStore(2)
        let coord = makeCoordinator(store: store, backend: refused)
        let a = coord.session(for: .myApp(ids[0]))
        let b = coord.session(for: .myApp(ids[1]))

        a.send("one")
        b.send("two")
        let bothArmed = await awaitUntil {
            a.lastError != nil && b.lastError != nil && !a.isStreaming && !b.isStreaming
        }
        #expect(bothArmed, "both chats' sends should fail and arm lastError")
        // Distinct threads → distinct per-thread replay logs on the backend.
        #expect(a.threadId != b.threadId)

        coord.reattachAllAfterForeground()

        // Both recovered independently. The per-thread after_seq wire is
        // unit-tested in AGUIKit ReattachTests; here we pin that the
        // coordinator drives recovery across concurrent chats.
        #expect(a.lastError == nil)
        #expect(b.lastError == nil)
    }
}
