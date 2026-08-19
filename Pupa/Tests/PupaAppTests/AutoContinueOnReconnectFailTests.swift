import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// The opt-in one-shot "continue" fallback
/// (`SettingsStore.autoContinueOnReconnectFail`): a foreground reattach whose
/// own stream errors out restarts the dropped turn with a single templated
/// message. Pins that it fires exactly once, only when armed, never on top of
/// an unresolved parked dispatch, and never outlives its own turn.
///
/// Failures are injected as a bare `400`: `AgentSession.isReattachable` is false
/// for it, so the error surfaces immediately instead of walking the four-step
/// reattach ladder (~7.5s). Disk-backed — the cached snapshot is what seeds the
/// replay cursor a reattach needs — hence `.serialized` + `TestStorage`.
@MainActor
@Suite("Auto-continue on reconnect fail", .serialized)
struct AutoContinueOnReconnectFailTests {

    init() { TestStorage.activate() }

    private func makeMemory() -> MemoryStore {
        MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pupa-tests-\(UUID().uuidString)"))
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelaunchMockURLProtocol.self]
        cfg.timeoutIntervalForRequest = 60   // a held-open POST must outlive the test
        return URLSession(configuration: cfg)
    }

    private func poll(timeout: Duration = .seconds(3), _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    /// The templated sends only — a real user message never counts as one.
    private func templates(_ vm: ChatViewModel) -> [ChatBubble] {
        vm.bubbles.filter { $0.role == .user && $0.text == ChatViewModel.autoReconnectContinueText }
    }

    /// A VM in the state `reattachIfNeeded` exists for: the cached snapshot says
    /// a turn was in flight, so first open seeds the replay cursor and fires a
    /// catch-up reattach — which fails, leaving a `connectionIssue` behind.
    /// `parkedAfterSeq` additionally parks that turn on a frontend tool.
    private func makeDroppedTurnVM(
        autoContinue: Bool,
        parkedAfterSeq: Int? = nil
    ) async -> ChatViewModel {
        await MyAppStore.clearStorage()
        SettingsStore.clearStorage()
        RelaunchMockURLProtocol.reset()
        MyAppTypeRegistry.shared.registerBuiltins()

        let app = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([app], app.id))
        let scope: ChatScope = .myApp(app.id)
        let tid = store.currentThreadId(for: scope)
        TranscriptCache.save(
            TranscriptSnapshot(bubbles: [ChatBubble(role: .user, text: "long question")],
                               lastEventSeq: 6, turnInFlight: true, savedAt: Date(),
                               pendingDispatchAfterSeq: parkedAfterSeq),
            threadId: tid)

        let settings = SettingsStore(backendURL: URL(string: "http://mock.test/")!,
                                     credentials: InMemoryCredentialStore())
        settings.setAutoContinueOnReconnectFail(autoContinue)
        RelaunchMockURLProtocol.statusPostAt = { _ in 400 }

        let vm = ChatViewModel(
            store: store, memory: makeMemory(), settings: settings,
            registry: ToolRegistry(), scope: scope, threadId: tid,
            urlSession: mockSession(), toolGateState: ToolGateState())
        vm.loadHistoryIfNeeded()
        _ = await poll { vm.connectionIssue != nil && !vm.isStreaming }
        return vm
    }

    @Test("Templated fallback message is a plain continue")
    func templateText() {
        #expect(ChatViewModel.autoReconnectContinueText == "continue")
    }

    // MARK: - Firing

    @Test("An armed reattach that still errors sends exactly one templated continue")
    func fires_onceAfterFailedReattach() async {
        let vm = await makeDroppedTurnVM(autoContinue: true)
        #expect(vm.connectionIssue != nil, "setup: the catch-up reattach must have failed")

        vm.reattachIfNeeded()

        #expect(await poll { templates(vm).count == 1 },
                "a failed armed reattach restarts the dropped turn with one continue")
        // That continue turn fails too (every POST is a 400). The arm is spent,
        // so the failure must not cascade into a second one.
        #expect(await poll { vm.connectionIssue != nil && !vm.isStreaming })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(templates(vm).count == 1, "one-shot: a later failure must not re-fire")
    }

    @Test("Setting off: a failed reattach never injects a continue")
    func neverFires_whenSettingOff() async {
        let vm = await makeDroppedTurnVM(autoContinue: false)

        vm.reattachIfNeeded()

        #expect(await poll { vm.connectionIssue != nil && !vm.isStreaming })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(templates(vm).isEmpty)
    }

    @Test("A reattach that settles without an error injects nothing")
    func neverFires_whenReattachSettlesClean() async {
        let vm = await makeDroppedTurnVM(autoContinue: true)
        // 204 → the replay buffer is gone; a benign no-op, not a failure.
        RelaunchMockURLProtocol.statusPostAt = nil

        vm.reattachIfNeeded()

        #expect(await poll { !vm.isStreaming })
        #expect(vm.connectionIssue == nil)
        #expect(templates(vm).isEmpty, "nothing errored — there is nothing to continue")
    }

    // MARK: - Precedence

    @Test("An unresolved parked dispatch owns the recovery — no continue on top of it")
    func neverFires_whileAParkedDispatchIsPending() async {
        let vm = await makeDroppedTurnVM(autoContinue: true, parkedAfterSeq: 4)
        #expect(vm.pendingDispatchAfterSeq == 4, "setup: the rewind point survives a failed catch-up")

        vm.reattachIfNeeded()

        #expect(await poll { vm.connectionIssue != nil && !vm.isStreaming })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(templates(vm).isEmpty,
                "a fresh run would drop the backend's pending command (pupa#258)")
        #expect(vm.pendingDispatchAfterSeq == 4, "the rewind point is left for the next attempt")
    }

    @Test("Genuinely queued input is sent instead of the template")
    func queuedInput_takesPrecedence() async {
        let vm = await makeDroppedTurnVM(autoContinue: true)
        RelaunchMockURLProtocol.postDelay = 0.4   // room to queue while the reattach is in flight

        vm.reattachIfNeeded()
        #expect(await poll { vm.isStreaming }, "setup: the armed reattach should be in flight")
        vm.send("do the other thing")
        #expect(vm.queuedMessages.count == 1, "setup: a send mid-turn queues")

        // The reattach fails, so the fallback hands off to the queue: banner
        // cleared, the user's own text drained, no template.
        #expect(await poll(timeout: .seconds(5)) { vm.queuedMessages.isEmpty && !vm.isStreaming })
        #expect(templates(vm).isEmpty)
        #expect(vm.bubbles.contains { $0.role == .user && $0.text == "do the other thing" },
                "the queued message must not be stranded behind the error banner")
    }

    // MARK: - The arm never outlives its turn

    /// The arm belongs to the reattach that set it. Whichever way that stream
    /// ends — a Stop mid-headers (here), a Stop mid-body, or an error — a later
    /// unrelated turn must never inherit it. `AgentSession` currently lands every
    /// Stop on the settle path's non-`cancelled` branch, where `didUserStop`
    /// consumes the arm, so this passes with or without `cancel`'s explicit
    /// `disarmAutoContinue()`; it pins the contract that disarm keeps true if
    /// that teardown ever surfaces as `AgentClientError.cancelled` instead.
    @Test("Stop on an armed reattach disarms it — no continue on a later failure")
    func staleArm_doesNotFireOnALaterTurn() async {
        let vm = await makeDroppedTurnVM(autoContinue: true)
        RelaunchMockURLProtocol.statusPostAt = nil
        RelaunchMockURLProtocol.postDelay = 30
        let before = RelaunchMockURLProtocol.postBodies.count

        vm.reattachIfNeeded()
        #expect(await poll { RelaunchMockURLProtocol.postBodies.count > before },
                "setup: the armed reattach POST should be in flight")
        try? await Task.sleep(for: .milliseconds(100))
        vm.cancel()
        #expect(await poll { !vm.isStreaming })

        // A later, unrelated turn fails. The spent arm must not resurrect.
        RelaunchMockURLProtocol.postDelay = nil
        RelaunchMockURLProtocol.statusPostAt = { _ in 400 }
        vm.send("something else")

        #expect(await poll { vm.connectionIssue != nil && !vm.isStreaming })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(templates(vm).isEmpty,
                "the arm belonged to the torn-down reattach, not to this turn")
    }
}
