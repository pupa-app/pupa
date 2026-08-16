import Foundation
import Testing
@testable import AGUIKit

/// Resume-confirmation contract for frontend-tool parks (pupa#258).
///
/// `.frontendDispatchParked` hands the host a rewind point; `.frontendDispatchResolved`
/// spends it. Every park must be paired with exactly one resolve, on the `send`
/// path as much as the recovery path, and in the order the host applies them —
/// an unpaired park leaves `turnInFlight` latched and re-runs the batch on the
/// next launch.
///
/// Nested inside `AgentSessionTests` for the same reason as `Reattach`: these
/// mutate `MockURLProtocol`'s non-isolated static state.
extension AgentSessionTests {
@Suite("Parked dispatch resume", .serialized)
struct ParkedResume {

    private static let sseHeaders: [String: String] = ["Content-Type": "text/event-stream"]

    private func makeClient() -> AgentClient {
        AgentClient(endpoint: URL(string: "http://mock.test/agent")!, session: makeMockSession())
    }

    private func freshSession(
        registry: ToolRegistry,
        journal: FrontendDispatchJournal? = nil
    ) -> AgentSession {
        MockURLProtocol.reset()
        return AgentSession(
            client: makeClient(),
            registry: registry,
            threadId: "test-thread",
            journal: journal
        )
    }

    private static func interruptFrame(id: String, name: String, args: String) -> String {
        let payload = #"{"frontend_tool_calls":[{"id":"\#(id)","name":"\#(name)","args":\#(args)}]}"#
        let escaped = payload
            .replacingOccurrences(of: "\\", with: #"\\"#)
            .replacingOccurrences(of: "\"", with: #"\""#)
        return #"{"type":"CUSTOM","name":"on_interrupt","value":"\#(escaped)"}"#
    }

    private func registry(_ recorder: ResumeCallRecorder) -> ToolRegistry {
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "addItem", description: "add", parameters: ["type": "object"]),
            handler: { _ in
                await recorder.record("addItem")
                return .object(["ok": .bool(true)])
            }
        ))
        return registry
    }

    /// The `command` key of request `idx` (0-based), or nil when the request
    /// was never made or carried none.
    private func command(requestIndex idx: Int) throws -> AnyJSON? {
        guard MockURLProtocol.requestBodies.indices.contains(idx) else { return nil }
        let input = try JSONDecoder().decode(
            RunAgentInput.self, from: MockURLProtocol.requestBodies[idx])
        return input.forwardedProps["command"]
    }

    private func collect(_ stream: AsyncThrowingStream<SessionEvent, Error>) async -> [SessionEvent] {
        var events: [SessionEvent] = []
        do { for try await ev in stream { events.append(ev) } } catch {}
        return events
    }

    /// Compact label per park/resolve event, so order can be asserted directly.
    private func parkTrace(_ events: [SessionEvent]) -> [String] {
        events.compactMap { ev in
            switch ev {
            case .frontendDispatchParked(let seq): return "parked(\(seq))"
            case .frontendDispatchResolved: return "resolved"
            default: return nil
            }
        }
    }

    // MARK: - The send() path

    /// The rewind point is persisted by the host the moment a park is announced.
    /// Without the matching resolve it is never spent: `turnInFlight` stays true
    /// in the snapshot forever, and the next launch rewinds to a long-finished
    /// interrupt and re-dispatches the whole batch.
    @Test("A send that parks and resumes resolves its rewind point")
    func sendPath_parkIsResolved() async throws {
        let recorder = ResumeCallRecorder()
        let session = freshSession(registry: registry(recorder), journal: TestResumeJournal())
        ResumeBodies.shared.rounds = [
            sseBodyWithIds([
                #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
                Self.interruptFrame(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#),
                #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
            ], startSeq: 0),
            sseBodyWithIds([
                #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
                #"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
                #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"done"}"#,
                #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
                #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
            ], startSeq: 3),
        ]
        ResumeBodies.shared.install()

        let events = await collect(session.send("add apple", context: { [] }))

        #expect(parkTrace(events) == ["parked(0)", "resolved"])
    }

    /// The journal must survive until the resume has demonstrably reached the
    /// backend — and then be dropped, so a later launch doesn't replay a spent
    /// batch. Both halves are the `send` path's, not just the recovery path's.
    @Test("A send clears the journal only after its resume lands")
    func sendPath_clearsJournalAfterResume() async throws {
        let recorder = ResumeCallRecorder()
        let journal = TestResumeJournal()
        let session = freshSession(registry: registry(recorder), journal: journal)
        ResumeBodies.shared.rounds = [
            sseBodyWithIds([
                #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
                Self.interruptFrame(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#),
                #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
            ], startSeq: 0),
            sseBodyWithIds([
                #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
                #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
            ], startSeq: 3),
        ]
        ResumeBodies.shared.install()

        _ = await collect(session.send("add apple", context: { [] }))

        #expect(await journal.records.isEmpty)
        #expect(await journal.clearsBeforeFirstRestore == 0,
                "clearing before the resume POST would lose the results")
    }

    // MARK: - Multiple parks in one turn

    /// The park is announced from inside the round (it rides its own frame's
    /// seq); the resolve is announced after the round returns. Emitted in that
    /// order, a second park's rewind point is written and then immediately
    /// nulled by the previous batch's resolve — so a kill during the second
    /// dispatch has nothing to rewind to.
    @Test("A turn that parks twice keeps the second rewind point")
    func twoParks_secondRewindPointSurvives() async throws {
        let recorder = ResumeCallRecorder()
        let session = freshSession(registry: registry(recorder), journal: TestResumeJournal())
        ResumeBodies.shared.rounds = [
            sseBodyWithIds([
                #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
                Self.interruptFrame(id: "call_A", name: "addItem", args: #"{"item":"a"}"#),
                #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
            ], startSeq: 0),
            sseBodyWithIds([
                #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
                Self.interruptFrame(id: "call_B", name: "addItem", args: #"{"item":"b"}"#),
                #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
            ], startSeq: 3),
            sseBodyWithIds([
                #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r3"}"#,
                #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r3"}"#,
            ], startSeq: 6),
        ]
        ResumeBodies.shared.install()

        let events = await collect(session.send("add two", context: { [] }))

        // Each park must be spent before the next is announced, so the host's
        // single rewind slot always holds the newest live park.
        #expect(parkTrace(events) == ["parked(0)", "resolved", "parked(3)", "resolved"])
    }

    // MARK: - Empty reattach tails

    /// A reattach that lands past the interrupt frame returns nothing, which is
    /// indistinguishable from "the park is gone". Deleting the journal on that
    /// evidence destroys the only record of a batch whose backend may still be
    /// parked — and the next launch then re-runs every side effect.
    @Test("An empty reattach tail keeps an outstanding journal")
    func emptyTail_keepsJournal() async throws {
        let recorder = ResumeCallRecorder()
        let journal = TestResumeJournal([
            "call_A": FrontendCallRecord(name: "addItem", result: .object(["ok": .bool(true)])),
        ])
        let session = freshSession(registry: registry(recorder), journal: journal)
        MockURLProtocol.responder = { _ in (200, Data(), Self.sseHeaders) }
        await session.seedReplayCursor(6)

        _ = await collect(session.reattach())

        #expect(await journal.records["call_A"] != nil,
                "an empty tail proves nothing about the park — keep the record")
    }

    // MARK: - Dropped resume POSTs

    /// A resume whose *response* was lost still reached the backend. Re-POSTing
    /// it then hits a session that has already been retired, which answers "no
    /// parked session" — surfacing an error for a turn that in fact completed
    /// and is sitting in the replay log. Reattaching first recovers it.
    @Test("A resume that landed is recovered by reattach, not reported as an error")
    func landedResume_recoveredByReattach() async throws {
        let recorder = ResumeCallRecorder()
        let session = freshSession(registry: registry(recorder), journal: TestResumeJournal())
        let park = sseBodyWithIds([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            Self.interruptFrame(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#),
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ], startSeq: 0)
        // The turn the backend actually ran after the resume landed. Only a
        // `command.reattach` can fetch it; a re-POSTed resume gets the error.
        let completedTail = sseBodyWithIds([
            #"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"Added apple."}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ], startSeq: 3)
        let noParkedSession = sseBody([
            #"{"type":"RUN_ERROR","message":"no parked Claude Code session for this thread"}"#,
        ])
        MockURLProtocol.responder = { _ in
            if MockURLProtocol.requestCount == 1 { return (200, park, Self.sseHeaders) }
            let body = MockURLProtocol.requestBodies.last ?? Data()
            let input = try? JSONDecoder().decode(RunAgentInput.self, from: body)
            let isReattach = input?.forwardedProps["command"]?["reattach"] != nil
            return (200, isReattach ? completedTail : noParkedSession, Self.sseHeaders)
        }
        // POST #2 is the resume: it arrives, but the response never comes back.
        MockURLProtocol.failer = { idx in idx == 2 ? URLError(.networkConnectionLost) : nil }

        let events = await collect(session.send("add apple", context: { [] }))

        let errors = events.compactMap { ev -> String? in
            if case .error(let message, _) = ev { return message }
            return nil
        }
        #expect(errors.isEmpty, "the turn completed — nothing to report as an error")
        let texts = events.compactMap { ev -> String? in
            if case .assistantMessageEnd(_, let text) = ev { return text }
            return nil
        }
        #expect(texts == ["Added apple."], "the completed turn must be recovered from the replay log")
        #expect(try command(requestIndex: 2)?["reattach"] != nil,
                "the first retry after a lost resume response must be a reattach")
    }

    /// The mirror case: the resume genuinely never arrived, so the replay log
    /// has nothing past the cursor. The empty tail is the signal to re-POST the
    /// results rather than declare the turn finished.
    @Test("An empty reattach tail after a dropped resume re-POSTs the results")
    func emptyTailAfterDrop_resendsResume() async throws {
        let recorder = ResumeCallRecorder()
        let session = freshSession(registry: registry(recorder), journal: TestResumeJournal())
        let park = sseBodyWithIds([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            Self.interruptFrame(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#),
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ], startSeq: 0)
        let finished = sseBodyWithIds([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ], startSeq: 3)
        MockURLProtocol.responder = { _ in
            if MockURLProtocol.requestCount == 1 { return (200, park, Self.sseHeaders) }
            let body = MockURLProtocol.requestBodies.last ?? Data()
            let input = try? JSONDecoder().decode(RunAgentInput.self, from: body)
            // The park is still waiting, so a reattach finds nothing buffered.
            if input?.forwardedProps["command"]?["reattach"] != nil {
                return (204, Data(), [:])
            }
            return (200, finished, Self.sseHeaders)
        }
        MockURLProtocol.failer = { idx in idx == 2 ? URLError(.networkConnectionLost) : nil }

        _ = await collect(session.send("add apple", context: { [] }))

        #expect(try command(requestIndex: 2)?["reattach"] != nil, "#3 probes the replay log")
        let resent = try #require(try command(requestIndex: 3)?["resume"])
        #expect(resent["tool_results"]?.arrayValue?.first?["toolCallId"]?.stringValue == "call_A",
                "an empty tail means the backend never got the results — re-POST them")
        #expect(await recorder.count == 1, "the tool must not run twice")
    }

    /// Against a backend that never stamps replay seqs there is no cursor, so a
    /// `command.reattach` carries `after_seq: -1` and an empty message list — it
    /// is not short-circuited by the replay middleware and reaches a real agent
    /// loop, retiring the parked session and starting an empty-prompt turn.
    @Test("An unstamped backend is never sent a bare reattach")
    func unstampedBackend_neverReattaches() async throws {
        let recorder = ResumeCallRecorder()
        let session = freshSession(registry: registry(recorder), journal: TestResumeJournal())
        // No `id:` lines anywhere — a backend predating the replay layer.
        let park = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            Self.interruptFrame(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#),
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        let finished = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ])
        MockURLProtocol.responder = { _ in
            (200, MockURLProtocol.requestCount == 1 ? park : finished, Self.sseHeaders)
        }
        // Every resume attempt but the last dies at connect time.
        MockURLProtocol.failer = { idx in (2...3).contains(idx) ? URLError(.networkConnectionLost) : nil }

        _ = await collect(session.send("add apple", context: { [] }))

        for idx in 1..<MockURLProtocol.requestBodies.count {
            #expect(try command(requestIndex: idx)?["reattach"] == nil,
                    "request \(idx + 1) reattached with no replay cursor")
        }
    }
}
}

// MARK: - Test doubles

/// In-memory `FrontendDispatchJournal` for the resume-confirmation tests.
private actor TestResumeJournal: FrontendDispatchJournal {
    private(set) var records: [String: FrontendCallRecord]
    private(set) var clearsBeforeFirstRestore = 0
    private var didRestore = false

    init(_ seed: [String: FrontendCallRecord] = [:]) { records = seed }

    func noteStarted(callId: String, name: String) {
        records[callId] = FrontendCallRecord(name: name)
    }

    func noteFinished(callId: String, result: AnyJSON) {
        records[callId] = FrontendCallRecord(name: records[callId]?.name ?? "", result: result)
    }

    func restore() -> [String: FrontendCallRecord] {
        didRestore = true
        return records
    }

    func clear() {
        if !didRestore { clearsBeforeFirstRestore += 1 }
        records.removeAll()
    }
}

private actor ResumeCallRecorder {
    private(set) var names: [String] = []
    var count: Int { names.count }
    func record(_ name: String) { names.append(name) }
}

/// Per-round SSE bodies served in order (same pattern as `Bodies` in `ReattachTests`).
private final class ResumeBodies: @unchecked Sendable {
    static let shared = ResumeBodies()
    var rounds: [Data] = []

    /// Serve `rounds[n]` for the nth request, repeating the last one after that.
    func install() {
        let bodies = rounds
        MockURLProtocol.responder = { _ in
            let idx = min(MockURLProtocol.requestCount - 1, bodies.count - 1)
            return (200, bodies[idx], ["Content-Type": "text/event-stream"])
        }
    }
}
