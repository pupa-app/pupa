import Foundation
import Testing
@testable import AGUIKit

/// The tool-round cap and the "turn ended early" outcomes.
///
/// The cap used to report a clean `.produced` whenever the turn had emitted any
/// assistant text — so a turn that narrated in round 1 and then burned through
/// the cap was indistinguishable from a normal finish and the UI showed nothing.
/// `.truncated(reason)` is the fix: text was produced AND the turn was cut
/// short. The same reordering applies to a stream that dies mid-turn.
///
/// The cap also has to unpark the backend. A computed dispatch has already run
/// its handlers (mutating local state) by the time the cap is checked, so the
/// loop drains — it keeps POSTing staged resumes, bounded by `maxDrainRounds`
/// — rather than returning and leaving the backend parked on results that never
/// arrive.
///
/// Nested inside `AgentSessionTests` (a `.serialized` suite) so it shares that
/// suite's single serial scope — `MockURLProtocol` keeps responder state in
/// non-isolated statics and swift-testing runs top-level suites in parallel.
extension AgentSessionTests {
@Suite("Turn cap + silent stops", .serialized)
struct TurnCap {

    private static let sseHeaders: [String: String] = ["Content-Type": "text/event-stream"]

    private func makeClient() -> AgentClient {
        AgentClient(endpoint: URL(string: "http://mock.test/agent")!, session: makeMockSession())
    }

    private func recordingRegistry(_ recorder: DispatchRecorder) -> ToolRegistry {
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "addItem", description: "add", parameters: ["type": "object"]),
            handler: { args in
                await recorder.record(args: args)
                return .object(["ok": .bool(true)])
            }
        ))
        return registry
    }

    /// A round that parks on a frontend-tool interrupt for `callId`.
    private static func interruptBody(callId: String) -> Data {
        let value = #"{\"frontend_tool_calls\":[{\"id\":\"\#(callId)\",\"name\":\"addItem\",\"args\":{}}]}"#
        return sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(value)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
        ])
    }

    /// Narration AND an interrupt in the same round — the shape that made cap
    /// hits invisible, since `producedText` then masked every cut-short reason.
    private static func textThenInterruptBody(callId: String) -> Data {
        let value = #"{\"frontend_tool_calls\":[{\"id\":\"\#(callId)\",\"name\":\"addItem\",\"args\":{}}]}"#
        return sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"Sure, adding that…"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(value)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
        ])
    }

    private static func emptyRoundBody() -> Data {
        sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
        ])
    }

    private func lastCompletion(
        _ stream: AsyncThrowingStream<SessionEvent, Error>
    ) async -> CompletionOutcome? {
        var last: CompletionOutcome?
        do {
            for try await ev in stream {
                if case .completed(let outcome) = ev { last = outcome }
            }
        } catch {}
        return last
    }

    // MARK: - Default

    @Test("The round cap is off by default — a finite default truncated long turns")
    func defaultCapIsUnlimited() async throws {
        MockURLProtocol.reset()
        let session = AgentSession(
            client: makeClient(), registry: ToolRegistry(), threadId: "test-thread")
        #expect(await session.maxRounds == nil)
    }

    @Test("setMaxRounds applies to the next send without rebuilding the session")
    func setMaxRoundsAppliesToNextSend() async throws {
        MockURLProtocol.reset()
        let recorder = DispatchRecorder()
        let session = AgentSession(
            client: makeClient(), registry: recordingRegistry(recorder), threadId: "test-thread")
        await session.setMaxRounds(1)
        #expect(await session.maxRounds == 1)

        // Every round parks again; only the cap can stop this.
        MockURLProtocol.responder = { _ in (200, Self.interruptBody(callId: "c"), Self.sseHeaders) }
        let outcome = await lastCompletion(session.send("go", context: { [] }))

        // Round 1 trips the cap, then the bounded drain: 3 POSTs, not unbounded.
        #expect(outcome == .silent(.maxRounds))
        #expect(MockURLProtocol.requestCount == 3)
    }

    // MARK: - The headline bug: a cap hit after narration

    @Test("A cap hit after the agent narrated is .truncated, not a clean .produced")
    func capHitAfterNarration_isTruncatedNotProduced() async throws {
        MockURLProtocol.reset()
        let recorder = DispatchRecorder()
        let session = AgentSession(
            client: makeClient(), registry: recordingRegistry(recorder), threadId: "test-thread",
            maxRounds: 1)

        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? Self.textThenInterruptBody(callId: "call_A")
                : Self.emptyRoundBody()
            return (200, body, Self.sseHeaders)
        }

        let outcome = await lastCompletion(session.send("go", context: { [] }))

        // Before the fix this was `.produced` — the turn narrated in round 1, so
        // `producedText` swallowed the cap and the UI drew no notice at all.
        #expect(outcome == .truncated(.maxRounds))
        #expect(outcome?.noticeReason == .maxRounds)
    }

    @Test("A clean settle after narration stays .produced — no spurious notice")
    func cleanSettleAfterNarration_staysProduced() async throws {
        MockURLProtocol.reset()
        let session = AgentSession(
            client: makeClient(), registry: ToolRegistry(), threadId: "test-thread")
        MockURLProtocol.responder = { _ in
            (200, sseBody([
                #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
                #"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
                #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"done"}"#,
                #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
                #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
            ]), Self.sseHeaders)
        }

        let outcome = await lastCompletion(session.send("go", context: { [] }))
        #expect(outcome == .produced)
        #expect(outcome?.noticeReason == nil)
    }

    // MARK: - Draining: never strand a parked backend

    @Test("A dispatch produced by the final capped round still gets its resume POST")
    func dispatchOnFinalCapRound_stillResumes() async throws {
        MockURLProtocol.reset()
        let recorder = DispatchRecorder()
        let session = AgentSession(
            client: makeClient(), registry: recordingRegistry(recorder), threadId: "test-thread",
            maxRounds: 1)

        // Round 1 parks on call_A. The drain round answers with ANOTHER
        // interrupt (call_B) — the old loop read that round only for its text
        // and dropped call_B, leaving the backend parked forever.
        MockURLProtocol.responder = { _ in
            switch MockURLProtocol.requestCount {
            case 1: return (200, Self.interruptBody(callId: "call_A"), Self.sseHeaders)
            case 2: return (200, Self.interruptBody(callId: "call_B"), Self.sseHeaders)
            default: return (200, Self.emptyRoundBody(), Self.sseHeaders)
            }
        }

        let outcome = await lastCompletion(session.send("go", context: { [] }))

        #expect(await recorder.count == 2)          // call_B ran too
        #expect(MockURLProtocol.requestCount == 3)  // …and its resume went out
        let resume = try JSONDecoder().decode(
            RunAgentInput.self, from: MockURLProtocol.requestBodies[2])
        let results = try #require(
            resume.forwardedProps["command"]?["resume"]?["tool_results"]?.arrayValue)
        #expect(results.first?["toolCallId"]?.stringValue == "call_B")
        #expect(outcome == .silent(.maxRounds))
    }

    @Test("The drain is bounded — a backend that parks every round can't loop forever")
    func drainBudgetIsBounded() async throws {
        MockURLProtocol.reset()
        let recorder = DispatchRecorder()
        let session = AgentSession(
            client: makeClient(), registry: recordingRegistry(recorder), threadId: "test-thread",
            maxRounds: 1)

        // Every round parks again. Round 1 trips the cap, then `maxDrainRounds`
        // (2) further POSTs flush staged results before the loop gives up: the
        // third drain attempt is refused, so 3 POSTs and 3 dispatches total.
        MockURLProtocol.responder = { _ in
            (200, Self.interruptBody(callId: "c"), Self.sseHeaders)
        }

        let outcome = await lastCompletion(session.send("go", context: { [] }))

        #expect(MockURLProtocol.requestCount == 3)
        #expect(await recorder.count == 3)
        #expect(outcome == .silent(.maxRounds))
    }

    // MARK: - Reattach honours the same contract

    @Test("reattach() at the cap POSTs its staged resume instead of stranding the backend")
    func reattachAtCap_stillResumes() async throws {
        MockURLProtocol.reset()
        let recorder = DispatchRecorder()
        let session = AgentSession(
            client: makeClient(), registry: recordingRegistry(recorder), threadId: "test-thread",
            maxRounds: 1)
        await session.seedReplayCursor(4)

        // #1 = the replayed tail, ending on an unserviced interrupt.
        // #2 = the resume the old loop never sent: it dispatched the tools
        //      (local side effects applied), built the resume input, then let
        //      the `while round < maxRounds` condition end the loop.
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? Self.interruptBody(callId: "call_R")
                : Self.emptyRoundBody()
            return (200, body, Self.sseHeaders)
        }

        let outcome = await lastCompletion(session.reattach())

        #expect(await recorder.count == 1)
        #expect(MockURLProtocol.requestCount == 2)
        let resume = try JSONDecoder().decode(
            RunAgentInput.self, from: MockURLProtocol.requestBodies[1])
        let results = try #require(
            resume.forwardedProps["command"]?["resume"]?["tool_results"]?.arrayValue)
        #expect(results.first?["toolCallId"]?.stringValue == "call_R")
        #expect(outcome == .silent(.maxRounds))
    }

    // MARK: - A stream that dies after the agent spoke

    @Test("A stream that ends without RUN_FINISHED after text is .truncated(.droppedStream)")
    func droppedStreamAfterText_isTruncated() async throws {
        MockURLProtocol.reset()
        let session = AgentSession(
            client: makeClient(), registry: ToolRegistry(), threadId: "test-thread")
        // Text, then EOF — no RUN_FINISHED. `settleOutcome` used to check
        // `producedText` first and call this a clean finish.
        MockURLProtocol.responder = { _ in
            (200, sseBody([
                #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
                #"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
                #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"partial"}"#,
                #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
            ]), Self.sseHeaders)
        }

        let outcome = await lastCompletion(session.send("go", context: { [] }))
        #expect(outcome == .truncated(.droppedStream))
    }
}
}

/// File-local recorder — the sibling suites each keep their own private copy.
private actor DispatchRecorder {
    private(set) var count: Int = 0
    private(set) var args: [AnyJSON] = []

    func record(args: AnyJSON) {
        self.count += 1
        self.args.append(args)
    }
}
