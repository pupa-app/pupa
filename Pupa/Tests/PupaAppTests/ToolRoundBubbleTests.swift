import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for the `toolRound` chat-bubble state machine in `ChatViewModel`.
/// These exercise `apply(_:)` directly with synthetic `SessionEvent`s so a
/// failure points at the state machine, not at AGUIKit or networking.
///
/// The screenshot regression: `AgentSession.runLoop` yields the events in the
/// order
///     `.toolCallStarted` → `.roundFinished` → `.toolCallFinished`
/// for a frontend tool. A naive implementation that closes the open
/// tool-round on `.roundFinished` will drop the paired `.toolCallFinished`
/// and the spinner stays spinning forever. The first test pins that this
/// can never regress.
@MainActor
@Suite("Tool-round bubble state machine")
struct ToolRoundBubbleTests {

    // MARK: - Helpers

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

    private func toolRoundBubble(_ vm: ChatViewModel) -> ChatBubble? {
        vm.bubbles.first(where: { $0.role == .toolRound })
    }

    // MARK: - Regression: spinner unfreezes after roundFinished

    /// Regression for the "spinner stuck" bug observed in the Book Tracker
    /// screenshot. For a single frontend tool call the event order is:
    ///   `.toolCallStarted` → `.roundFinished` → `.toolCallFinished`
    /// (the last one fires from `AgentSession.runLoop` *after* the inner
    /// `runOneRound` has already emitted `.roundFinished`). A handler that
    /// clears `openToolRoundId` on `.roundFinished` will orphan the pending
    /// entry. This test pins that the entry flips to `.done` end-to-end.
    @Test("Single-tool round: pending→done across roundFinished gap (spinner unfreezes)")
    func singleTool_pendingFlipsToDone_acrossRoundFinishedGap() {
        let vm = makeViewModel()

        vm.apply(.toolCallStarted(id: "call_1", name: "addTrackerItems"))

        // Sanity: bubble exists with one pending entry — spinner is showing.
        let mid = toolRoundBubble(vm)
        #expect(mid?.toolEntries.count == 1)
        #expect(mid?.toolEntries.first?.state == .pending)

        // The `.roundFinished` in the middle is the trap door — must not
        // close the round, otherwise the next event below is dropped.
        vm.apply(.roundFinished(threadId: "t", runId: "r1"))

        vm.apply(.toolCallFinished(
            id: "call_1",
            name: "addTrackerItems",
            arguments: .object(["title": .string("Buy milk")]),
            result: .object(["ok": .bool(true), "id": .string("item_1")])
        ))

        let finalBubble = toolRoundBubble(vm)
        let entry = finalBubble?.toolEntries.first
        #expect(entry != nil)
        #expect(entry?.state == .done, "spinner must flip to done despite roundFinished firing in between")
        #expect(entry?.id == "call_1")
        #expect(entry?.name == "addTrackerItems")
        // Verbose-mode payloads are pretty-printed and non-empty.
        #expect(entry?.argsJSON.contains("Buy milk") == true)
        #expect(entry?.resultText.contains("item_1") == true)
    }

    // MARK: - Grouping: one bubble per round, fresh bubble after text

    /// Two consecutive `.toolCallStarted` events (no text in between) land in
    /// the same `toolRound` bubble. After the LLM resumes narration via
    /// `.assistantMessageStart`, the next tool call opens a fresh bubble.
    /// This matches the plan's "between two assistant text messages" grouping.
    @Test("Grouping: tools share one bubble until assistant text, then a new bubble opens")
    func grouping_oneBubblePerNarrativeSegment() {
        let vm = makeViewModel()

        // First batch — two tools in the same round.
        vm.apply(.toolCallStarted(id: "call_A", name: "renderTracker"))
        vm.apply(.toolCallStarted(id: "call_B", name: "addTrackerItems"))
        vm.apply(.roundFinished(threadId: "t", runId: "r1"))
        vm.apply(.toolCallFinished(
            id: "call_A", name: "renderTracker",
            arguments: .object([:]),
            result: .object(["ok": .bool(true)])
        ))
        vm.apply(.toolCallFinished(
            id: "call_B", name: "addTrackerItems",
            arguments: .object([:]),
            result: .object(["ok": .bool(true)])
        ))

        let firstBubbles = vm.bubbles.filter { $0.role == .toolRound }
        #expect(firstBubbles.count == 1, "Both tools must share one bubble — got \(firstBubbles.count)")
        #expect(firstBubbles.first?.toolEntries.map(\.id) == ["call_A", "call_B"])
        #expect(firstBubbles.first?.toolEntries.allSatisfy { $0.state == .done } == true)

        // LLM resumes narration — closes the open round.
        vm.apply(.assistantMessageStart(messageId: "m1"))
        vm.apply(.assistantMessageDelta(messageId: "m1", delta: "tracker is set up. now I'll add the next item."))
        vm.apply(.assistantMessageEnd(messageId: "m1", text: "tracker is set up. now I'll add the next item."))

        // Next tool call must open a NEW bubble.
        vm.apply(.toolCallStarted(id: "call_C", name: "addTrackerItems"))
        vm.apply(.toolCallFinished(
            id: "call_C", name: "addTrackerItems",
            arguments: .object([:]),
            result: .object(["ok": .bool(true)])
        ))

        let allBubbles = vm.bubbles.filter { $0.role == .toolRound }
        #expect(allBubbles.count == 2, "Post-text tool call must open a fresh bubble — got \(allBubbles.count)")
        #expect(allBubbles.last?.toolEntries.map(\.id) == ["call_C"])
        #expect(allBubbles.last?.toolEntries.first?.state == .done)
    }

    // MARK: - Failure classification

    /// A tool whose result is `{ok: false, error: "..."}` (AGUIKit's standard
    /// failure shape — see the `catch` branches in `AgentSession.runLoop`)
    /// must classify the entry as `.failed` so the UI can render an orange
    /// icon and a "K failed" suffix in the title.
    @Test("Failed result (ok:false) classifies entry as .failed")
    func failureClassification_okFalseMarksEntryFailed() {
        let vm = makeViewModel()

        vm.apply(.toolCallStarted(id: "call_x", name: "renderTracker"))
        vm.apply(.toolCallFinished(
            id: "call_x",
            name: "renderTracker",
            arguments: .object([:]),
            result: .object([
                "ok": .bool(false),
                "error": .string("typeId must be one of …"),
            ])
        ))

        let bubble = toolRoundBubble(vm)
        #expect(bubble?.toolEntries.first?.state == .failed)
    }

    /// Inverse — a healthy `{ok: true, …}` result is `.done`, and a result
    /// that isn't an object at all (e.g. backend tool returning a raw string)
    /// also defaults to `.done` rather than misclassifying as `.failed`.
    @Test("Non-failure shapes default to .done, not .failed")
    func failureClassification_otherShapesAreDone() {
        let vm = makeViewModel()

        vm.apply(.toolCallStarted(id: "call_a", name: "addTrackerItems"))
        vm.apply(.toolCallFinished(
            id: "call_a", name: "addTrackerItems",
            arguments: .object([:]),
            result: .object(["ok": .bool(true), "id": .string("item_1")])
        ))

        vm.apply(.toolCallStarted(id: "call_b", name: "tavily_search"))
        vm.apply(.toolCallFinished(
            id: "call_b", name: "tavily_search",
            arguments: .object([:]),
            result: .string("plain backend text result")
        ))

        // A backend tool with no server-emitted TOOL_CALL_RESULT — `.nil`
        // result. Should still be considered `.done`, not `.failed`.
        vm.apply(.toolCallStarted(id: "call_c", name: "tavily_search"))
        vm.apply(.toolCallFinished(
            id: "call_c", name: "tavily_search",
            arguments: .object([:]),
            result: nil
        ))

        let bubble = toolRoundBubble(vm)
        #expect(bubble?.toolEntries.map(\.state) == [.done, .done, .done])
    }

    // MARK: - Regression: shell-approval spinner stuck across rounds

    /// Regression for the "Calling 1 tool…" spinner stuck after the shell
    /// approval flow. The exact event order observed in production:
    ///
    /// Round 1: `.toolCallStarted(shell, tc1)` opens bubble A.
    /// Approval dispatch yields `.toolCallFinished(request_shell_approval, tc1)`
    /// → flips bubble A's entry to `.done` (shares the id by design).
    /// Round 2 (after resume): server emits `.assistantMessageStart` (model 2
    /// starts), which resets `openToolRoundId = nil`, then re-emits
    /// `.toolCallStarted(shell, tc1)`. A per-open-bubble dedupe misses,
    /// opens a fresh bubble B with a `.pending` entry, and the trailing
    /// `.toolCallFinished` (fallback-scanned) flips bubble A instead —
    /// bubble B's spinner never resolves. The dedupe must scan ALL toolRound
    /// bubbles so the duplicate `toolCallStarted` is a no-op.
    @Test("Duplicate toolCallStart for same id after assistantMessageStart is deduped — no orphan bubble")
    func dedupe_acrossAssistantMessageStart_noOrphanBubble() {
        let vm = makeViewModel()

        // Round 1 — model emits text, then a tool call. Tool not yet finished.
        vm.apply(.assistantMessageStart(messageId: "m1"))
        vm.apply(.assistantMessageDelta(messageId: "m1", delta: "Let me check!"))
        vm.apply(.assistantMessageEnd(messageId: "m1", text: "Let me check!"))
        vm.apply(.toolCallStarted(id: "tc1", name: "shell"))

        // Approval dispatch finishes (request_shell_approval shares the id).
        vm.apply(.toolCallFinished(
            id: "tc1", name: "request_shell_approval",
            arguments: .object(["command": .string("pwd")]),
            result: .object(["approved": .bool(true), "remember": .bool(false)])
        ))

        // Round 2 — model 2 starts narrating first, then the shell start is
        // re-emitted (this is the event order that triggered the bug).
        vm.apply(.assistantMessageStart(messageId: "m2"))
        vm.apply(.toolCallStarted(id: "tc1", name: "shell"))
        vm.apply(.assistantMessageDelta(messageId: "m2", delta: "My workspace is /tmp"))
        vm.apply(.assistantMessageEnd(messageId: "m2", text: "My workspace is /tmp"))
        vm.apply(.toolCallFinished(
            id: "tc1", name: "shell",
            arguments: .object(["command": .string("pwd")]),
            result: .string("/tmp\n")
        ))

        let toolRounds = vm.bubbles.filter { $0.role == .toolRound }
        #expect(toolRounds.count == 1, "Only one toolRound bubble should exist for a single tool call id — got \(toolRounds.count)")
        #expect(toolRounds.first?.toolEntries.count == 1)
        #expect(toolRounds.first?.toolEntries.first?.state == .done, "The single entry must end in .done — stuck spinner regression")
    }
}
