import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for the inline notice `ChatViewModel` shows when a turn settles
/// without any assistant reply — so a silent stop no longer just drops the
/// spinner and looks like the agent died. Drives `apply(_:)` directly with
/// synthetic `SessionEvent`s.
@MainActor
@Suite("Silent-completion notice")
struct SilentCompletionNoticeTests {

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

    @Test("A silent completion appends one system notice bubble")
    func silentCompletion_appendsSystemNotice() {
        let vm = makeViewModel()
        vm.apply(.completed(.silent(.emptyTurn)))
        let notices = systemBubbles(vm)
        #expect(notices.count == 1)
        #expect(notices.first?.text == ChatViewModel.silentStopMessage(.emptyTurn))
    }

    @Test("A produced completion appends no notice")
    func producedCompletion_appendsNothing() {
        let vm = makeViewModel()
        vm.apply(.completed(.produced))
        #expect(systemBubbles(vm).isEmpty)
    }

    @Test("A user Stop suppresses the notice for a late silent completion")
    func userStop_suppressesNotice() {
        let vm = makeViewModel()
        // No pending interrupt → cancel() takes Case B and flags the stop.
        vm.cancel()
        vm.apply(.completed(.silent(.droppedStream)))
        #expect(systemBubbles(vm).isEmpty)
    }

    @Test("Each silent reason maps to a distinct, non-empty message")
    func silentReasons_haveDistinctMessages() {
        let reasons: [SilentReason] = [
            .emptyTurn, .maxRounds, .droppedStream, .droppedInterrupt, .backend("boom"),
        ]
        let messages = reasons.map { ChatViewModel.silentStopMessage($0) }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == reasons.count)
        #expect(ChatViewModel.silentStopMessage(.backend("boom")).contains("boom"))
    }

    /// The regression this suite exists for: a turn that narrated first and
    /// then hit the round cap reported `.produced` and drew nothing at all, so
    /// the spinner just vanished after a tool call.
    @Test("A truncated completion appends a notice even though the agent replied")
    func truncatedCompletion_appendsSystemNotice() {
        let vm = makeViewModel()
        vm.apply(.completed(.truncated(.maxRounds)))
        let notices = systemBubbles(vm)
        #expect(notices.count == 1)
        #expect(notices.first?.text == ChatViewModel.silentStopMessage(.maxRounds))
    }

    @Test("A user Stop suppresses the notice for a late truncated completion too")
    func userStop_suppressesTruncatedNotice() {
        let vm = makeViewModel()
        vm.cancel()
        vm.apply(.completed(.truncated(.maxRounds)))
        #expect(systemBubbles(vm).isEmpty)
    }

    @Test("A dropped stream reads differently once the agent had already replied")
    func droppedStream_wordingSplitsOnTruncation() {
        let vm = makeViewModel()
        vm.apply(.completed(.truncated(.droppedStream)))
        let notice = systemBubbles(vm).first?.text
        #expect(notice == ChatViewModel.silentStopMessage(.droppedStream, truncated: true))
        #expect(notice != ChatViewModel.silentStopMessage(.droppedStream))
        #expect(notice?.contains("mid-reply") == true)
    }
}
