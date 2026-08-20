import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// The connection banner's Continue affordance (`continueDroppedTurn`): the
/// user-initiated restart of a turn whose stream died. What it does depends on
/// what the backend is still holding — re-attach when there's a tail or a parked
/// dispatch, re-send the dropped message when nothing ever streamed — so each
/// branch is pinned separately, as is the inertness when nothing is stuck.
///
/// Deterministic without a live backend: a refused port fails the POST fast, so
/// the turn surfaces a `connectionIssue`; a blackholed address hangs connect,
/// keeping a stream live (same trick as `ReattachForegroundTests`). The re-send
/// test asserts the wire itself via `RelaunchMockURLProtocol.postBodies`, whose
/// statics are shared — hence `.serialized`.
@MainActor
@Suite("Continue a dropped turn", .serialized)
struct ContinueDroppedTurnTests {

    /// This suite persists transcripts (every settle calls `persistTranscript`),
    /// so it must write to the shared temp root rather than real storage.
    init() { TestStorage.activate() }

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

    private func userBubbles(_ vm: ChatViewModel, text: String) -> [ChatBubble] {
        vm.bubbles.filter { $0.role == .user && $0.text == text }
    }

    /// Text of the last user message on the wire, from the recorded POST body.
    private func lastUserMessageSent() -> String? {
        guard let body = RelaunchMockURLProtocol.postBodies.last,
              let input = try? JSONDecoder().decode(RunAgentInput.self, from: body),
              let last = input.messages.last(where: { $0.role == .user }),
              case .text(let text) = last.content
        else { return nil }
        return text
    }

    /// POSTs that carried a message, i.e. spent a turn. A re-attach carries an
    /// empty message list, so this is what separates "re-attached" from
    /// "re-sent" — the two outcomes look identical from `bubbles` alone.
    private func sendPostCount() -> Int {
        RelaunchMockURLProtocol.postBodies.filter { body in
            guard let input = try? JSONDecoder().decode(RunAgentInput.self, from: body) else { return false }
            return !input.messages.isEmpty
        }.count
    }

    /// `after_seq` of the last POST, when it was a re-attach.
    private func lastReattachAfterSeq() -> Int? {
        guard let body = RelaunchMockURLProtocol.postBodies.last,
              let input = try? JSONDecoder().decode(RunAgentInput.self, from: body),
              input.messages.isEmpty
        else { return nil }
        return input.forwardedProps["command"]?["reattach"]?["after_seq"]?.intValue
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelaunchMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private let mockBackend = URL(string: "http://mock.test/")!

    // MARK: - Nothing streamed → re-send the dropped message

    /// The POST never landed, so the backend has no record of the turn and the
    /// run never started. Re-sending the *dropped message* is the recovery — a
    /// template would be worse than useless: `AgentSession` replaces a trailing
    /// user message that didn't settle, so it would erase what the user asked.
    @Test("Nothing streamed: re-sends the dropped message, not a template")
    func continueDroppedTurn_resendsDroppedMessage() async {
        RelaunchMockURLProtocol.reset()
        RelaunchMockURLProtocol.failPostAt = { _ in URLError(.cannotConnectToHost) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelaunchMockURLProtocol.self]
        let (store, id) = makeStore()
        let vm = makeVM(store: store, id: id, backend: URL(string: "http://mock.test/")!,
                        session: URLSession(configuration: cfg))

        vm.send("what is the weather")
        #expect(await awaitUntil { vm.connectionIssue != nil && !vm.isStreaming })
        #expect(vm.appliedEventSeq == nil, "setup: nothing streamed, so there is no replay cursor")

        vm.continueDroppedTurn()

        #expect(await awaitUntil { RelaunchMockURLProtocol.postBodies.count == 2 })
        #expect(lastUserMessageSent() == "what is the weather",
                "the retry carries the user's own message")
        #expect(userBubbles(vm, text: "what is the weather").count == 1,
                "the bubble is already on screen — no duplicate")
        #expect(userBubbles(vm, text: ChatViewModel.continueDroppedTurnText).isEmpty)
        #expect(await awaitUntil { !vm.isStreaming })
        RelaunchMockURLProtocol.reset()
    }

    /// Nothing to re-send (a hydrated transcript whose user bubbles were never
    /// cached) falls back to the template rather than doing nothing.
    @Test("No message to retry: falls back to the plain template")
    func continueDroppedTurn_fallsBackToTemplate() async {
        let (store, id) = makeStore()
        let vm = makeVM(store: store, id: id, backend: refused)
        vm.apply(.error(message: "backend blew up", code: nil))
        #expect(vm.connectionIssue != nil, "setup: a failure with no user bubble behind it")

        vm.continueDroppedTurn()

        #expect(userBubbles(vm, text: ChatViewModel.continueDroppedTurnText).count == 1)
        #expect(await awaitUntil { !vm.isStreaming })
    }

    // MARK: - Backend is holding something → re-attach

    /// Frames arrived before the socket died, so the backend's replay buffer
    /// holds the rest of the turn. A fresh run would advance the cursor past it
    /// and strand an answer it may already have produced.
    @Test("A replay tail exists: re-attaches instead of sending")
    func continueDroppedTurn_tailReattaches() async {
        RelaunchMockURLProtocol.reset()
        RelaunchMockURLProtocol.failPostAt = { _ in URLError(.cannotConnectToHost) }
        let (store, id) = makeStore()
        let vm = makeVM(store: store, id: id, backend: mockBackend, session: mockSession())

        vm.send("hi")
        #expect(await awaitUntil { vm.connectionIssue != nil && !vm.isStreaming })
        #expect(sendPostCount() == 1, "setup: one turn spent so far")
        vm.apply(.cursorAdvanced(5))
        #expect(vm.appliedEventSeq == 5, "setup: part of this turn streamed")

        vm.continueDroppedTurn()

        #expect(vm.connectionIssue == nil, "recovery is under way — the banner cleared")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(sendPostCount() == 1, "re-attach carries no message — no second turn was spent")
        #expect(userBubbles(vm, text: ChatViewModel.continueDroppedTurnText).isEmpty)
        vm.cancel()
        #expect(await awaitUntil { !vm.isStreaming }, "no work may outlive the test")
        RelaunchMockURLProtocol.reset()
    }

    /// A turn parked on a frontend tool is resumed by re-attaching, never by a
    /// fresh run: the backend is holding a command that a new run would drop,
    /// and the rewind point must survive for the next attempt (pupa#258).
    @Test("A pending parked dispatch is re-attached, not restarted")
    func continueDroppedTurn_parkedDispatchReattaches() async {
        RelaunchMockURLProtocol.reset()
        RelaunchMockURLProtocol.failPostAt = { _ in URLError(.cannotConnectToHost) }
        let (store, id) = makeStore()
        let vm = makeVM(store: store, id: id, backend: mockBackend, session: mockSession())

        vm.send("hi")
        #expect(await awaitUntil { vm.connectionIssue != nil && !vm.isStreaming })
        vm.apply(.frontendDispatchParked(afterSeq: 4))
        #expect(vm.pendingDispatchAfterSeq == 4, "setup: the turn is parked on a frontend tool")

        vm.continueDroppedTurn()

        #expect(vm.isStreaming, "the parked turn is being re-attached")
        #expect(vm.connectionIssue == nil, "re-attach cleared the banner")
        // The re-attach rewinds to the parked frame so the backend re-sends the
        // call list — a fresh run would drop the command it is holding.
        #expect(await awaitUntil { RelaunchMockURLProtocol.postBodies.count == 2 })
        #expect(lastReattachAfterSeq() == 4, "the retry re-attaches at the rewind point")
        #expect(sendPostCount() == 1, "no second turn was spent")
        #expect(vm.pendingDispatchAfterSeq == 4, "the rewind point survives for the retry")
        vm.cancel()   // tidy the reattach (it sits in the session's retry ladder)
        #expect(await awaitUntil { !vm.isStreaming }, "no work may outlive the test")
        RelaunchMockURLProtocol.reset()
    }

    // MARK: - Inert when nothing is stuck

    @Test("Continue is a no-op when nothing is stuck")
    func continueDroppedTurn_noOpWhenClean() {
        let (store, id) = makeStore()
        let vm = makeVM(store: store, id: id, backend: refused)

        vm.continueDroppedTurn()   // fresh VM: no connectionIssue

        #expect(vm.bubbles.isEmpty)
        #expect(!vm.isStreaming)
    }

    /// An error frame can land while the stream is still live, so the banner and
    /// a running turn coexist. Tapping then must not touch the turn — and must
    /// not quietly queue anything either, which is how `send` would swallow it.
    @Test("Continue is a no-op while a stream is live")
    func continueDroppedTurn_noOpWhileStreaming() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        let (store, id) = makeStore()
        // 192.0.2.1 (TEST-NET-1) blackholes connect → the POST hangs, stream stays live.
        let vm = makeVM(store: store, id: id, backend: URL(string: "http://192.0.2.1/")!,
                        session: URLSession(configuration: cfg))

        vm.send("hi")
        #expect(await awaitUntil(500) { vm.isStreaming })
        vm.apply(.error(message: "backend blew up", code: nil))
        #expect(vm.connectionIssue != nil, "setup: banner up while the turn is still live")
        #expect(vm.isStreaming)

        vm.continueDroppedTurn()

        #expect(vm.queuedMessages.isEmpty, "a live turn has nothing stuck to continue")
        #expect(userBubbles(vm, text: ChatViewModel.continueDroppedTurnText).isEmpty)
        #expect(userBubbles(vm, text: "hi").count == 1)
        vm.cancel()   // tidy the hanging task
        #expect(await awaitUntil { !vm.isStreaming }, "no work may outlive the test")
    }
}
