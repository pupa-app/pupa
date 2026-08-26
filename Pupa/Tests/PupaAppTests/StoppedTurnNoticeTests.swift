import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// The notice `ChatViewModel` raises when a turn settles without ever really
/// finishing — so a silent stop no longer just drops the spinner and looks
/// like the agent died. Drives `apply(_:)` directly with synthetic
/// `SessionEvent`s.
///
/// This is the *notice* ending, and it is the common one: `runOneRound`
/// swallows reattachable drops into its retry ladder and rethrows only once
/// the budget is spent, so most stopped turns arrive here rather than through
/// `connectionIssue`. It used to render a transcript bubble telling the user
/// to type "continue" by hand, while the Continue button — gated on
/// `connectionIssue` — never appeared. Now both endings raise a banner and
/// both offer the button.
@MainActor
@Suite("Stopped-turn notice")
struct StoppedTurnNoticeTests {

    init() { TestStorage.activate() }

    private func makeViewModel() -> ChatViewModel {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        let memory = MemoryStore(
            rootOverride: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pupa-tests-\(UUID().uuidString)")
        )
        return ChatViewModel(
            store: store,
            memory: memory,
            settings: SettingsStore(backendURL: URL(string: "http://localhost:65535/")!),
            registry: ToolRegistry(),
            scope: .myApp(myApp.id),
            threadId: store.currentThreadId(for: .myApp(myApp.id)),
            toolGateState: ToolGateState()
        )
    }

    private func systemBubbles(_ vm: ChatViewModel) -> [ChatBubble] {
        vm.bubbles.filter { $0.role == .system }
    }

    @Test("A silent completion raises one resumable notice")
    func silentCompletion_raisesNotice() {
        let vm = makeViewModel()
        vm.apply(.completed(.silent(.emptyTurn)))
        #expect(vm.stoppedNotice?.reason == .emptyTurn)
        #expect(vm.stoppedNotice?.isResumable == true)
        #expect(vm.stoppedNotice?.message == ChatViewModel.stoppedTurnMessage(.emptyTurn))
    }

    @Test("A produced completion raises nothing")
    func producedCompletion_raisesNothing() {
        let vm = makeViewModel()
        vm.apply(.completed(.produced))
        #expect(vm.stoppedNotice == nil)
        #expect(systemBubbles(vm).isEmpty)
    }

    @Test("A user Stop suppresses the notice for a late silent completion")
    func userStop_suppressesNotice() {
        let vm = makeViewModel()
        // No pending interrupt → cancel() takes Case B and flags the stop.
        vm.cancel()
        vm.apply(.completed(.silent(.droppedStream)))
        #expect(vm.stoppedNotice == nil)
    }

    @Test("Each reason maps to a distinct, non-empty message")
    func reasons_haveDistinctMessages() {
        let reasons: [SilentReason] = [
            .emptyTurn, .maxRounds, .droppedStream, .droppedInterrupt, .backend("boom"),
        ]
        let messages = reasons.map { ChatViewModel.stoppedTurnMessage($0) }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == reasons.count)
        #expect(ChatViewModel.stoppedTurnMessage(.backend("boom")).contains("boom"))
    }

    /// The regression the original suite existed for: a turn that narrated
    /// first and then hit the round cap reported `.produced` and drew nothing
    /// at all, so the spinner just vanished after a tool call.
    @Test("A truncated completion raises a notice even though the agent replied")
    func truncatedCompletion_raisesNotice() {
        let vm = makeViewModel()
        vm.apply(.completed(.truncated(.maxRounds)))
        #expect(vm.stoppedNotice?.reason == .maxRounds)
        #expect(vm.stoppedNotice?.truncated == true)
    }

    @Test("A user Stop suppresses the notice for a late truncated completion too")
    func userStop_suppressesTruncatedNotice() {
        let vm = makeViewModel()
        vm.cancel()
        vm.apply(.completed(.truncated(.maxRounds)))
        #expect(vm.stoppedNotice == nil)
    }

    @Test("A dropped stream reads differently once the agent had already replied")
    func droppedStream_wordingSplitsOnTruncation() {
        let vm = makeViewModel()
        vm.apply(.completed(.truncated(.droppedStream)))
        #expect(vm.stoppedNotice?.message
            == ChatViewModel.stoppedTurnMessage(.droppedStream, truncated: true))
        #expect(vm.stoppedNotice?.message
            != ChatViewModel.stoppedTurnMessage(.droppedStream))
        #expect(vm.stoppedNotice?.message.contains("mid-reply") == true)
    }

    // MARK: - The affordance

    /// The bug, pinned: the notice must not put a call to action in the
    /// transcript, and must not leave a bubble that outlives the button.
    @Test("A stopped turn leaves no transcript bubble and no instruction to type")
    func stoppedTurn_leavesNoBubble() {
        for reason: SilentReason in [.emptyTurn, .maxRounds, .droppedStream, .droppedInterrupt] {
            let vm = makeViewModel()
            vm.apply(.completed(.silent(reason)))
            #expect(systemBubbles(vm).isEmpty, "\(reason) still writes a bubble")
            #expect(
                vm.bubbles.allSatisfy { !$0.text.localizedCaseInsensitiveContains("continue") },
                "\(reason) still asks the user to type “continue”")
        }
    }

    /// `.backend` is the agent reporting a real failure — there is nothing to
    /// continue from, so it is the one reason that offers no button.
    @Test("A backend stop is not resumable")
    func backendStop_isNotResumable() {
        let vm = makeViewModel()
        vm.apply(.completed(.silent(.backend("boom"))))
        #expect(vm.stoppedNotice?.isResumable == false)
    }

    /// Routing the notice ending by cursor would send it to `reattachIfNeeded`
    /// — a clean completion always leaves `appliedEventSeq` set — which reads
    /// an empty tail and settles the turn again. The user would press Continue
    /// and watch nothing happen.
    @Test("Continue re-sends on the notice ending instead of re-attaching")
    func continueOnNotice_sendsRatherThanReattaches() {
        let vm = makeViewModel()
        vm.apply(.cursorAdvanced(4))
        vm.apply(.completed(.silent(.emptyTurn)))
        #expect(vm.appliedEventSeq == 4, "setup: the turn streamed, then stopped short")

        vm.continueDroppedTurn()

        #expect(vm.stoppedNotice == nil, "the notice is spent once acted on")
        #expect(
            vm.bubbles.contains { $0.role == .user && $0.text == ChatViewModel.continueDroppedTurnText },
            "Continue neither re-sent nor re-attached")
        vm.cancel()
    }

    @Test("Continue is inert when nothing is stuck")
    func continue_isInertWhenIdle() {
        let vm = makeViewModel()
        vm.continueDroppedTurn()
        #expect(vm.bubbles.isEmpty)
        #expect(!vm.isStreaming)
    }
}
