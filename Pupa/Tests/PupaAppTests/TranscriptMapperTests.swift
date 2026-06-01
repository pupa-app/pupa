import Foundation
import Testing
@testable import PupaApp

/// Tests for `TranscriptMapper.bubbles(from:)` — the function that maps a flat
/// `[TranscriptMessage]` list from the backend transcript endpoint into the
/// `[ChatBubble]` shape the chat UI renders.
@Suite("TranscriptMapper")
struct TranscriptMapperTests {

    // MARK: - Helpers

    private func human(_ text: String, id: String = UUID().uuidString) -> TranscriptMessage {
        TranscriptMessage(id: id, role: "human", content: text, toolCalls: [], toolCallId: nil)
    }

    private func ai(_ text: String, id: String = UUID().uuidString) -> TranscriptMessage {
        TranscriptMessage(id: id, role: "ai", content: text, toolCalls: [], toolCallId: nil)
    }

    private func aiWithToolCall(
        text: String = "",
        callId: String,
        name: String,
        id: String = UUID().uuidString
    ) -> TranscriptMessage {
        TranscriptMessage(
            id: id,
            role: "ai",
            content: text,
            toolCalls: [TranscriptToolCall(id: callId, name: name, args: [:])],
            toolCallId: nil
        )
    }

    private func toolResult(_ text: String, callId: String, id: String = UUID().uuidString) -> TranscriptMessage {
        TranscriptMessage(id: id, role: "tool", content: text, toolCalls: [], toolCallId: callId)
    }

    // MARK: - Empty

    @Test("Empty input produces empty output")
    func emptyInput() {
        #expect(TranscriptMapper.bubbles(from: []).isEmpty)
    }

    // MARK: - Human messages

    @Test("Human messages map to .user bubbles")
    func humanMessage() {
        let bubbles = TranscriptMapper.bubbles(from: [human("Hello")])
        #expect(bubbles.count == 1)
        #expect(bubbles[0].role == .user)
        #expect(bubbles[0].text == "Hello")
    }

    @Test("Human message id is preserved")
    func humanMessageId() {
        let bubbles = TranscriptMapper.bubbles(from: [human("Hi", id: "msg-h1")])
        #expect(bubbles[0].id == "msg-h1")
    }

    // MARK: - AI messages

    @Test("Plain AI message maps to .assistant bubble")
    func aiMessage() {
        let bubbles = TranscriptMapper.bubbles(from: [ai("Sure!")])
        #expect(bubbles.count == 1)
        #expect(bubbles[0].role == .assistant)
        #expect(bubbles[0].text == "Sure!")
    }

    @Test("AI message with nil id gets a generated id")
    func aiMessageNilId() {
        let msg = TranscriptMessage(id: nil, role: "ai", content: "hi", toolCalls: [], toolCallId: nil)
        let bubbles = TranscriptMapper.bubbles(from: [msg])
        #expect(!bubbles[0].id.isEmpty)
    }

    // MARK: - Tool rounds

    @Test("AI message with tool calls + matching tool result maps to one .toolRound bubble")
    func toolRound_singleCall() {
        let msgs: [TranscriptMessage] = [
            human("Use the tool"),
            aiWithToolCall(callId: "tc-1", name: "addItem"),
            toolResult("ok", callId: "tc-1"),
            ai("Done!"),
        ]
        let bubbles = TranscriptMapper.bubbles(from: msgs)

        #expect(bubbles.count == 3, "human, toolRound, assistant")
        #expect(bubbles[0].role == .user)
        #expect(bubbles[1].role == .toolRound)
        #expect(bubbles[1].toolEntries.count == 1)
        #expect(bubbles[1].toolEntries[0].name == "addItem")
        #expect(bubbles[1].toolEntries[0].resultText == "ok")
        #expect(bubbles[1].toolEntries[0].state == .done)
        #expect(bubbles[2].role == .assistant)
        #expect(bubbles[2].text == "Done!")
    }

    @Test("Multiple tool calls in one AI message all appear in the same toolRound bubble")
    func toolRound_multipleCalls() {
        let msgs: [TranscriptMessage] = [
            aiWithToolCall(callId: "tc-1", name: "toolA"),
            // second tool call on a *separate* AI message is unusual but possible
            TranscriptMessage(
                id: "ai-2",
                role: "ai",
                content: "",
                toolCalls: [
                    TranscriptToolCall(id: "tc-2", name: "toolB", args: [:]),
                    TranscriptToolCall(id: "tc-3", name: "toolC", args: [:]),
                ],
                toolCallId: nil
            ),
            toolResult("result-1", callId: "tc-1"),
            toolResult("result-2", callId: "tc-2"),
            toolResult("result-3", callId: "tc-3"),
        ]
        let bubbles = TranscriptMapper.bubbles(from: msgs)

        // First AI (1 call) → toolRound; second AI (2 calls) → toolRound
        let rounds = bubbles.filter { $0.role == .toolRound }
        #expect(rounds.count == 2)
        #expect(rounds[0].toolEntries.count == 1)
        #expect(rounds[1].toolEntries.count == 2)
    }

    @Test("Tool call without a matching result message still appears as .done (result empty)")
    func toolRound_missingResult() {
        let msgs: [TranscriptMessage] = [
            aiWithToolCall(callId: "tc-x", name: "ghost"),
            // No tool result follows
            ai("Continuing anyway"),
        ]
        let bubbles = TranscriptMapper.bubbles(from: msgs)
        let round = bubbles.first(where: { $0.role == .toolRound })
        #expect(round != nil)
        #expect(round!.toolEntries[0].resultText == "")
        #expect(round!.toolEntries[0].state == .done)
    }

    @Test("Tool call id is used to match result, not position")
    func toolRound_idBasedMatching() {
        // Results arrive out of position order — matching must use toolCallId.
        let msgs: [TranscriptMessage] = [
            TranscriptMessage(
                id: "ai-1",
                role: "ai",
                content: "",
                toolCalls: [
                    TranscriptToolCall(id: "tc-A", name: "first", args: [:]),
                    TranscriptToolCall(id: "tc-B", name: "second", args: [:]),
                ],
                toolCallId: nil
            ),
            toolResult("result-B", callId: "tc-B"),
            toolResult("result-A", callId: "tc-A"),
        ]
        let bubbles = TranscriptMapper.bubbles(from: msgs)
        let round = bubbles.first(where: { $0.role == .toolRound })!
        let entryA = round.toolEntries.first(where: { $0.id == "tc-A" })!
        let entryB = round.toolEntries.first(where: { $0.id == "tc-B" })!
        #expect(entryA.resultText == "result-A")
        #expect(entryB.resultText == "result-B")
    }

    // MARK: - Order preservation

    @Test("Multi-turn transcript is rendered in chronological order")
    func multiTurnOrder() {
        let msgs: [TranscriptMessage] = [
            human("First"),
            ai("Reply 1"),
            human("Second"),
            ai("Reply 2"),
        ]
        let bubbles = TranscriptMapper.bubbles(from: msgs)
        #expect(bubbles.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(bubbles[0].text == "First")
        #expect(bubbles[1].text == "Reply 1")
        #expect(bubbles[2].text == "Second")
        #expect(bubbles[3].text == "Reply 2")
    }

    @Test("Orphan tool messages (no preceding ai-with-tool-calls) are skipped")
    func orphanToolMessageSkipped() {
        // A stray "tool" role with no AI-with-tool-calls before it.
        let msgs: [TranscriptMessage] = [
            human("Hi"),
            toolResult("stray", callId: "tc-orphan"),
            ai("Hello"),
        ]
        let bubbles = TranscriptMapper.bubbles(from: msgs)
        // The stray tool message is consumed as an unknown role → skipped.
        let roles = bubbles.map(\.role)
        #expect(!roles.contains(.toolRound), "No tool round for orphan tool message")
        #expect(roles == [.user, .assistant])
    }
}
