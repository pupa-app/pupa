import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for the lifecycle properties of a per-scope `ChatViewModel`.
///
/// Key semantic changes from the pre-multi-thread model:
/// - `newThread()` appends a new thread to the store and calls `cancel()`,
///   but does NOT clear the current VM's `bubbles` — the `ConversationPager`
///   creates a fresh VM for the new thread, keeping the old one intact for
///   swipe-back.
/// - `ChatViewModel` takes an explicit `threadId` parameter at init (the
///   coordinator resolves it from `store.currentThreadId(for:)`).
@MainActor
@Suite("ChatViewModel lifecycle")
struct ChatViewModelLifecycleTests {

    private func makeViewModel(
        store: MyAppStore,
        memory: MemoryStore,
        scope: ChatScope,
        threadId: String? = nil
    ) -> ChatViewModel {
        let tid = threadId ?? store.currentThreadId(for: scope)
        return ChatViewModel(
            store: store,
            memory: memory,
            settings: SettingsStore(backendURL: URL(string: "http://localhost:65535/")!),
            registry: ToolRegistry(),
            scope: scope,
            threadId: tid,
            toolGateState: ToolGateState()
        )
    }

    private func makeMemory() -> MemoryStore {
        MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pupa-tests-\(UUID().uuidString)"))
    }

    @Test("Initial state: bubbles empty, not streaming, no error")
    func initialState() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(myApp.id))

        #expect(vm.bubbles.isEmpty)
        #expect(vm.isStreaming == false)
        #expect(vm.connectionIssue == nil)
        #expect(vm.pinnedScope == .myApp(myApp.id))
        #expect(vm.threadId == store.currentThreadId(for: .myApp(myApp.id)))
        // A fresh VM is idle with nothing unviewed.
        #expect(vm.hasUnviewedCompletion == false)
        #expect(vm.activityStatus == .idle)
    }

    @Test("markViewed() clears the unviewed-answer flag and is safe on a fresh VM")
    func markViewedClears() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(myApp.id))

        vm.markViewed()
        #expect(vm.hasUnviewedCompletion == false)
        #expect(vm.activityStatus == .idle)
    }

    @Test("newThread() on a myApp scope adds a thread to the store and makes it current — other scopes untouched")
    func newThreadAddsThreadForBoundScope() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let b = MyApp(name: "B", iconSystemName: "square", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a, b], a.id))

        let initialA = store.currentThreadId(for: .myApp(a.id))
        let initialB = store.currentThreadId(for: .myApp(b.id))
        let initialMemory = store.memoryCurrentThreadId
        let initialACount = store.threads(for: .myApp(a.id)).count

        let vmA = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(a.id))
        vmA.newThread()

        // A new thread is current for scope A, and the list grew by one.
        let afterA = store.currentThreadId(for: .myApp(a.id))
        #expect(afterA != initialA)
        #expect(store.threads(for: .myApp(a.id)).count == initialACount + 1)

        // B and memory are completely untouched.
        #expect(store.currentThreadId(for: .myApp(b.id)) == initialB)
        #expect(store.memoryCurrentThreadId == initialMemory)
    }

    @Test("newThread() in memory scope adds only to memory threads — myApps untouched")
    func newThreadInMemoryScope() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))

        let initialA = store.currentThreadId(for: .myApp(a.id))
        let initialMemory = store.memoryCurrentThreadId
        let initialMemoryCount = store.memoryThreads.count

        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .memory)
        vm.newThread()

        #expect(store.memoryCurrentThreadId != initialMemory)
        #expect(store.memoryThreads.count == initialMemoryCount + 1)
        #expect(store.currentThreadId(for: .myApp(a.id)) == initialA)
    }

    @Test("newThread() does NOT clear the current VM's bubbles — the pager creates a fresh VM")
    func newThreadPreservesBubbles() async {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(a.id))

        // Plant a bubble manually to simulate a conversation in progress.
        vm.apply(.assistantMessageStart(messageId: "msg-1"))
        vm.apply(.assistantMessageEnd(messageId: "msg-1", text: "Hello"))
        #expect(vm.bubbles.count == 1)

        vm.newThread()

        // Old VM keeps its bubbles so the user can swipe back and read them.
        #expect(vm.bubbles.count == 1, "newThread must not clear the old VM's bubbles")
    }

    @Test("threadId is immutable and matches the store's thread for this scope at init time")
    func threadIdIsImmutable() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let expectedId = store.currentThreadId(for: .myApp(a.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(a.id))
        #expect(vm.threadId == expectedId)

        // After newThread() the store moves to a new thread — this VM keeps its old id.
        vm.newThread()
        #expect(vm.threadId == expectedId)
        #expect(store.currentThreadId(for: .myApp(a.id)) != expectedId)
    }

    @Test("memoryFocusedPath is mutable and round-trips through the viewmodel")
    func memoryFocusedPathRoundTrips() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .memory)

        #expect(vm.memoryFocusedPath == "")
        vm.memoryFocusedPath = "notes/diet.md"
        #expect(vm.memoryFocusedPath == "notes/diet.md")
    }

    @Test("Two viewmodels for two myApps have distinct identity and independent state")
    func twoViewModelsAreIndependent() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let b = MyApp(name: "B", iconSystemName: "square", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a, b], a.id))

        let vmA = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(a.id))
        let vmB = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(b.id))

        #expect(vmA !== vmB)
        #expect(vmA.pinnedScope == .myApp(a.id))
        #expect(vmB.pinnedScope == .myApp(b.id))
        #expect(vmA.threadId != vmB.threadId)
    }

    // MARK: - Title capture

    @Test("deriveTitle returns first ~6 words, capped at 40 chars")
    func deriveTitle() {
        #expect(ChatViewModel.deriveTitle("Hello world") == "Hello world")
        #expect(ChatViewModel.deriveTitle("  hi  ") == "hi")
        let long = "one two three four five six seven eight"
        let derived = ChatViewModel.deriveTitle(long)
        // Up to 6 words
        #expect(derived == "one two three four five six")
        let veryLong = String(repeating: "x", count: 50)
        #expect(ChatViewModel.deriveTitle(veryLong).count == 40)
        // Multi-line: only uses first line
        #expect(ChatViewModel.deriveTitle("first line\nsecond line") == "first line")
    }

    // MARK: - ask_user_questions / HumanInTheLoopBridge

    private func awaitBubbleAppear(_ vm: ChatViewModel) async {
        for _ in 0..<100 {
            if !vm.bubbles.isEmpty { return }
            await Task.yield()
        }
    }

    @Test("askQuestions appends a multi-row humanQuestion bubble and arms pending state")
    func askQuestions_rendersMultiRowBubble_andFlagsPending() async {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(a.id))

        #expect(vm.hasPendingQuestion == false)

        async let answers = vm.askQuestions([
            HumanQuestionRow(question: "Use existing or create new?", options: ["Use existing", "Create new"]),
            HumanQuestionRow(question: "Which list?", options: ["TBR", "Finished"]),
            HumanQuestionRow(question: "Notes?", options: []),
        ])
        await awaitBubbleAppear(vm)

        #expect(vm.hasPendingQuestion == true)
        #expect(vm.bubbles.count == 1)
        let bubble = vm.bubbles[0]
        #expect(bubble.role == .humanQuestion)
        #expect(bubble.humanQuestions.count == 3)
        #expect(bubble.humanQuestions[0].question == "Use existing or create new?")
        #expect(bubble.humanQuestions[0].options == ["Use existing", "Create new"])
        #expect(bubble.humanQuestions[2].options == [])
        #expect(vm.pendingAnswers == ["", "", ""])
        #expect(vm.pendingAnswersComplete == false)

        // Cancel via newThread() so the async let resolves and the test doesn't hang.
        vm.newThread()
        _ = await answers
    }

    @Test("setPendingAnswer fills slots; pendingAnswersComplete flips when all rows are non-empty")
    func setPendingAnswer_tracksPerRowState() async {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(a.id))

        async let answers = vm.askQuestions([
            HumanQuestionRow(question: "Q1?", options: []),
            HumanQuestionRow(question: "Q2?", options: []),
        ])
        await awaitBubbleAppear(vm)
        #expect(vm.pendingAnswersComplete == false)

        vm.setPendingAnswer(rowIndex: 0, value: "a1")
        #expect(vm.pendingAnswers == ["a1", ""])
        #expect(vm.pendingAnswersComplete == false)

        vm.setPendingAnswer(rowIndex: 1, value: "a2")
        #expect(vm.pendingAnswers == ["a1", "a2"])
        #expect(vm.pendingAnswersComplete == true)

        vm.setPendingAnswer(rowIndex: 99, value: "junk")
        #expect(vm.pendingAnswers == ["a1", "a2"])

        vm.setPendingAnswer(rowIndex: 1, value: "   ")
        #expect(vm.pendingAnswersComplete == false)

        vm.newThread()
        _ = await answers
    }

    @Test("submitInterruptAnswers clears pending state, appends a transcript bubble, and returns answers")
    func submitInterruptAnswers_clearsAndSummarises() async {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(a.id))

        vm.submitInterruptAnswers()
        #expect(vm.bubbles.isEmpty)

        async let answers = vm.askQuestions([
            HumanQuestionRow(question: "Q1?", options: []),
            HumanQuestionRow(question: "Q2?", options: []),
        ])
        await awaitBubbleAppear(vm)

        vm.setPendingAnswer(rowIndex: 0, value: "a1")
        vm.submitInterruptAnswers()
        #expect(vm.hasPendingQuestion == true)
        #expect(vm.bubbles.count == 1)

        vm.setPendingAnswer(rowIndex: 1, value: "a2")
        vm.submitInterruptAnswers()

        #expect(vm.hasPendingQuestion == false)
        #expect(vm.pendingAnswers.isEmpty)
        #expect(vm.bubbles.count == 2)
        #expect(vm.bubbles[1].role == .user)
        #expect(vm.bubbles[1].text == "1. a1\n2. a2")

        let result = await answers
        #expect(result == ["a1", "a2"])
    }

    @Test("Single-question submit summary is just the answer text, no numbering")
    func submitInterruptAnswers_singleRow_summaryIsBare() async {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(a.id))

        async let answers = vm.askQuestions([
            HumanQuestionRow(question: "Which book?", options: []),
        ])
        await awaitBubbleAppear(vm)
        vm.setPendingAnswer(rowIndex: 0, value: "The Pragmatic Programmer")
        vm.submitInterruptAnswers()

        #expect(vm.bubbles[1].text == "The Pragmatic Programmer")
        _ = await answers
    }

    @Test("newThread() clears pending question state and resumes the bridge with empty answers")
    func newThreadClearsPendingState() async {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(a.id))

        async let answers = vm.askQuestions([
            HumanQuestionRow(question: "Q?", options: []),
        ])
        await awaitBubbleAppear(vm)
        vm.setPendingAnswer(rowIndex: 0, value: "draft")
        #expect(vm.hasPendingQuestion == true)

        vm.newThread()

        #expect(vm.hasPendingQuestion == false)
        #expect(vm.pendingAnswers.isEmpty)
        // Note: bubbles are NOT cleared — the old VM keeps them so the
        // user can swipe back and read the conversation.
        let result = await answers
        #expect(result.isEmpty, "newThread → cancel → empty answers so the dispatch loop unblocks")
    }

    @Test("cancel() clears pending question state and resumes the bridge with empty answers")
    func cancelClearsPendingState() async {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(a.id))

        async let answers = vm.askQuestions([
            HumanQuestionRow(question: "Q?", options: []),
        ])
        await awaitBubbleAppear(vm)
        vm.setPendingAnswer(rowIndex: 0, value: "draft")

        vm.cancel()

        #expect(vm.hasPendingQuestion == false)
        #expect(vm.pendingAnswers.isEmpty)
        #expect(vm.bubbles.count == 1)
        let result = await answers
        #expect(result.isEmpty)
    }

    @Test("send(_:) while a question is pending is a no-op")
    func sendWhilePending_isNoOp() async {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let vm = makeViewModel(store: store, memory: makeMemory(), scope: .myApp(a.id))

        async let answers = vm.askQuestions([
            HumanQuestionRow(question: "Which one?", options: []),
        ])
        await awaitBubbleAppear(vm)
        let countBefore = vm.bubbles.count
        let pendingBefore = vm.hasPendingQuestion

        vm.send("a stray typed message")

        #expect(vm.bubbles.count == countBefore, "send should be a no-op while parked")
        #expect(vm.hasPendingQuestion == pendingBefore)

        vm.newThread()
        _ = await answers
    }
}
