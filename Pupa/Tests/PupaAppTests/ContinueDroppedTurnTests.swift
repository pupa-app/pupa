import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// The connection banner's Continue affordance (`continueDroppedTurn`): the
/// user-initiated restart of a turn whose stream died. Pins that it acts only
/// when something is genuinely stuck, and that it defers to the parked-dispatch
/// recovery rather than starting a run on top of it.
///
/// Deterministic without a mock transport: a refused port fails the POST fast,
/// so the turn surfaces a `connectionIssue`; a blackholed address hangs connect,
/// keeping a stream live (same trick as `ReattachForegroundTests`).
@MainActor
@Suite("Continue a dropped turn")
struct ContinueDroppedTurnTests {

    private let refused = URL(string: "http://localhost:65535/")!

    private func makeMemory() -> MemoryStore {
        MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pupa-tests-\(UUID().uuidString)"))
    }

    private func makeStore() -> (store: MyAppStore, id: UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let app = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        return (MyAppStore(initial: ([app], app.id)), app.id)
    }

    private func makeVM(
        store: MyAppStore, id: UUID, backend: URL, session: URLSession = .shared
    ) -> ChatViewModel {
        ChatViewModel(
            store: store, memory: makeMemory(),
            settings: SettingsStore(backendURL: backend),
            registry: ToolRegistry(), scope: .myApp(id),
            threadId: store.currentThreadId(for: .myApp(id)),
            urlSession: session, toolGateState: ToolGateState())
    }

    private func awaitUntil(_ ms: Int = 2000, _ cond: @escaping () -> Bool) async -> Bool {
        for _ in 0..<(ms / 10) {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    private func continues(_ vm: ChatViewModel) -> [ChatBubble] {
        vm.bubbles.filter { $0.role == .user && $0.text == ChatViewModel.continueDroppedTurnText }
    }

    @Test("Continue sends one plain 'continue' and clears the banner")
    func continueDroppedTurn_sends() async {
        let (store, id) = makeStore()
        let vm = makeVM(store: store, id: id, backend: refused)

        vm.send("hi")   // POST to a refused port → the turn surfaces a connectionIssue
        #expect(await awaitUntil { vm.connectionIssue != nil && !vm.isStreaming })

        vm.continueDroppedTurn()

        #expect(continues(vm).count == 1, "the tap sends exactly one templated message")
        #expect(vm.connectionIssue == nil, "sending clears the banner")
        #expect(vm.isStreaming, "the restarted turn is in flight")
        #expect(await awaitUntil { !vm.isStreaming })   // let it settle (fails again)
    }

    @Test("Continue is a no-op when nothing is stuck")
    func continueDroppedTurn_noOpWhenClean() {
        let (store, id) = makeStore()
        let vm = makeVM(store: store, id: id, backend: refused)

        vm.continueDroppedTurn()   // fresh VM: no connectionIssue

        #expect(continues(vm).isEmpty)
        #expect(!vm.isStreaming)
    }

    @Test("Continue is a no-op while a stream is live")
    func continueDroppedTurn_noOpWhileStreaming() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1
        cfg.timeoutIntervalForResource = 1
        let (store, id) = makeStore()
        // 192.0.2.1 (TEST-NET-1) blackholes connect → the POST hangs, stream stays live.
        let vm = makeVM(store: store, id: id, backend: URL(string: "http://192.0.2.1/")!,
                        session: URLSession(configuration: cfg))

        vm.send("hi")
        #expect(await awaitUntil(500) { vm.isStreaming })

        vm.continueDroppedTurn()

        #expect(continues(vm).isEmpty, "a live turn has nothing stuck to continue")
        vm.cancel()   // tidy the hanging task
    }

    /// A turn parked on a frontend tool is resumed by re-attaching, never by a
    /// fresh run: the backend is holding a command that a new run would drop,
    /// and the rewind point must survive for the next attempt (pupa#258).
    @Test("A pending parked dispatch is re-attached, not restarted")
    func continueDroppedTurn_parkedDispatchReattaches() async {
        let (store, id) = makeStore()
        let vm = makeVM(store: store, id: id, backend: refused)

        vm.send("hi")
        #expect(await awaitUntil { vm.connectionIssue != nil && !vm.isStreaming })
        vm.apply(.frontendDispatchParked(afterSeq: 4))
        #expect(vm.pendingDispatchAfterSeq == 4, "setup: the turn is parked on a frontend tool")

        vm.continueDroppedTurn()

        #expect(continues(vm).isEmpty, "a fresh run would drop the backend's pending command")
        #expect(vm.pendingDispatchAfterSeq == 4, "the rewind point survives for the retry")
        vm.cancel()   // tidy the reattach (it sits in the session's retry ladder)
    }
}
