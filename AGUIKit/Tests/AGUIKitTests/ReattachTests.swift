import Foundation
import Testing
@testable import AGUIKit

/// Tests for the resumable-SSE client (pupa#103 / pupa-backend#40).
///
/// Covers the four new surfaces:
///   - `AgentClient.runSequenced` parses the SSE `id:` field into
///     `SequencedAgentEvent.seq`, and treats `204 No Content` as a clean empty
///     round (the backend's answer for an unknown/evicted thread).
///   - `AgentSession` tracks the highest seq (`lastEventSeq`) and, on
///     `reattach()`, POSTs `command.reattach.after_seq` with an empty
///     messages/tools body — no-op when it never saw a seq.
///   - A replayed tail that ends on a frontend-tool interrupt is dispatched and
///     resumed exactly like a live turn.
///   - A dropped socket (connect-time failure) mid-turn re-attaches with
///     backoff and settles.
///
/// Nested inside `AgentSessionTests` (a `.serialized` suite) so it shares that
/// suite's single serial scope — both mutate `MockURLProtocol`'s non-isolated
/// static state, and swift-testing runs separate top-level suites in parallel,
/// which would race the shared mock.
extension AgentSessionTests {
@Suite("Resumable SSE reattach", .serialized)
struct Reattach {

    private static let sseHeaders: [String: String] = ["Content-Type": "text/event-stream"]

    private func makeClient() -> AgentClient {
        AgentClient(endpoint: URL(string: "http://mock.test/agent")!, session: makeMockSession())
    }

    private func freshSession(registry: ToolRegistry = ToolRegistry()) -> AgentSession {
        MockURLProtocol.reset()
        return AgentSession(client: makeClient(), registry: registry, threadId: "test-thread")
    }

    /// A normal 5-frame text round stamped with ids `0…4`; the session's
    /// `lastEventSeq` ends at 4.
    private static func idStampedTextRound() -> Data {
        sseBodyWithIds([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"hello"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
        ])
    }

    private func drain(_ stream: AsyncThrowingStream<SessionEvent, Error>) async {
        do { for try await _ in stream {} } catch {}
    }

    // MARK: - AgentClient: seq parsing + 204

    @Test("runSequenced parses the SSE id: field into seq; frames without id: are nil")
    func runSequenced_parsesSeqFromIdField() async throws {
        MockURLProtocol.reset()
        // Two id-stamped frames, then one with no id: line.
        let body = Data((
            "id: 7\ndata: {\"type\":\"RUN_STARTED\",\"threadId\":\"t\",\"runId\":\"r\"}\n\n" +
            "id: 8\ndata: {\"type\":\"TEXT_MESSAGE_START\",\"messageId\":\"m\",\"role\":\"assistant\"}\n\n" +
            "data: {\"type\":\"RUN_FINISHED\",\"threadId\":\"t\",\"runId\":\"r\"}\n\n"
        ).utf8)
        MockURLProtocol.responder = { _ in (200, body, Self.sseHeaders) }

        let client = makeClient()
        let input = RunAgentInput(threadId: "t", messages: [], tools: [], context: [])
        var seqs: [Int?] = []
        for try await ev in client.runSequenced(input) { seqs.append(ev.seq) }

        #expect(seqs == [7, 8, nil])
    }

    @Test("runSequenced treats 204 No Content as a clean empty round (no events)")
    func runSequenced_204IsEmptyCleanFinish() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responder = { _ in (204, Data(), [:]) }

        let client = makeClient()
        let input = RunAgentInput(threadId: "t", messages: [], tools: [], context: [])
        var count = 0
        for try await _ in client.runSequenced(input) { count += 1 }

        #expect(count == 0)
        #expect(MockURLProtocol.requestCount == 1)
    }

    // MARK: - AgentSession.reattach()

    @Test("reattach() with no replay cursor is a no-op: yields .completed, makes zero POSTs")
    func reattach_noCursor_noOp() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in (200, Self.idStampedTextRound(), Self.sseHeaders) }

        var events: [String] = []
        for try await ev in session.reattach() {
            if case .completed = ev { events.append("completed") }
        }

        #expect(events == ["completed"])
        // Never streamed → no seq seen → reattaching would hit a real agent
        // loop with an empty message list, so the session must not POST.
        #expect(MockURLProtocol.requestCount == 0)
    }

    @Test("reattach() after a streamed turn POSTs command.reattach.after_seq with an empty body")
    func reattach_afterTurn_postsAfterSeq() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in
            let n = MockURLProtocol.requestCount
            // #1 = the send (sets cursor to 4). #2 = the reattach replay tail.
            let body = n == 1
                ? Self.idStampedTextRound()
                : sseBodyWithIds([
                    #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
                    #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
                  ], startSeq: 5)
            return (200, body, Self.sseHeaders)
        }

        await drain(session.send("hi", context: { [] }))
        await drain(session.reattach())

        #expect(MockURLProtocol.requestCount == 2)
        let reattachBody = MockURLProtocol.requestBodies[1]
        let input = try JSONDecoder().decode(RunAgentInput.self, from: reattachBody)
        // Highest seq from the send round was 4 → reattach asks for everything after it.
        #expect(input.forwardedProps["command"]?["reattach"]?["after_seq"]?.intValue == 4)
        // The replay branch short-circuits in the middleware — no agent loop
        // ever sees this input, so messages/tools stay empty.
        #expect(input.messages.isEmpty)
        #expect(input.tools.isEmpty)
    }

    @Test("reattach() whose replayed tail ends on a frontend interrupt dispatches it and resumes")
    func reattach_replayedInterrupt_dispatchesAndResumes() async throws {
        let recorder = DispatchRecorder()
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "addItem", description: "add", parameters: ["type": "object"]),
            handler: { args in
                await recorder.record(args: args)
                return .object(["ok": .bool(true)])
            }
        ))
        let session = freshSession(registry: registry)

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_A\",\"name\":\"addItem\",\"args\":{\"item\":{\"name\":\"apple\"}}}]}"#
        Bodies.shared.reset()
        Bodies.shared.a = Self.idStampedTextRound()                       // #1 send → cursor 4
        Bodies.shared.b = sseBodyWithIds([                                // #2 reattach replay → interrupt
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ], startSeq: 5)
        Bodies.shared.c = sseBodyWithIds([                                // #3 resume → final answer
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r3"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"mf","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"mf","delta":"added"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"mf"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r3"}"#,
        ], startSeq: 8)
        MockURLProtocol.responder = { _ in
            let body: Data
            switch MockURLProtocol.requestCount {
            case 1: body = Bodies.shared.a!
            case 2: body = Bodies.shared.b!
            default: body = Bodies.shared.c!
            }
            return (200, body, Self.sseHeaders)
        }

        await drain(session.send("hi", context: { [] }))

        var finishedIds: [String] = []
        var completed = false
        for try await ev in session.reattach() {
            switch ev {
            case .toolCallFinished(let id, _, _, _): finishedIds.append(id)
            case .completed: completed = true
            default: break
            }
        }

        #expect(await recorder.count == 1)          // the parked tool ran locally
        #expect(finishedIds == ["call_A"])
        #expect(completed)
        // send + reattach-replay + resume = 3 POSTs.
        #expect(MockURLProtocol.requestCount == 3)
        // The 3rd POST is the resume carrying the dispatched tool's result.
        let resume = try JSONDecoder().decode(RunAgentInput.self, from: MockURLProtocol.requestBodies[2])
        let results = try #require(resume.forwardedProps["command"]?["resume"]?["tool_results"]?.arrayValue)
        #expect(results.first?["toolCallId"]?.stringValue == "call_A")
    }

    // MARK: - In-flight drop → backoff re-attach

    /// A resume round whose socket dies at connect time (a `requestFailed`) must
    /// re-attach to the replay log with backoff and settle, rather than
    /// surfacing the drop. Only the initial-connect failure is re-attachable;
    /// the first round can't (no cursor yet), so the drop is staged on round 2.
    @Test("Connect-time drop on the resume round re-attaches with backoff and completes")
    func inFlightDrop_reattachesAndCompletes() async throws {
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "addItem", description: "add", parameters: ["type": "object"]),
            handler: { _ in .object(["ok": .bool(true)]) }
        ))
        let session = freshSession(registry: registry)

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_A\",\"name\":\"addItem\",\"args\":{}}]}"#
        Bodies.shared.reset()
        Bodies.shared.a = sseBodyWithIds([                                // #1 send → cursor + interrupt
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        Bodies.shared.c = sseBodyWithIds([                                // #3 reattach retry → settles
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r3"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"mf","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"mf","delta":"recovered"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"mf"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r3"}"#,
        ], startSeq: 3)
        // POST #2 is the resume round — kill it at connect time.
        MockURLProtocol.failer = { idx in idx == 2 ? URLError(.networkConnectionLost) : nil }
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1 ? Bodies.shared.a! : Bodies.shared.c!
            return (200, body, Self.sseHeaders)
        }

        var completed = false
        for try await ev in session.send("hi", context: { [] }) {
            if case .completed = ev { completed = true }
        }

        #expect(completed)
        // send(1) + resume-that-drops(2) + reattach-retry(3).
        #expect(MockURLProtocol.requestCount == 3)
        // The recovery POST re-attaches (never re-sends the resume) — it carries
        // command.reattach, not command.resume.
        let retry = try JSONDecoder().decode(RunAgentInput.self, from: MockURLProtocol.requestBodies[2])
        #expect(retry.forwardedProps["command"]?["reattach"] != nil)
    }
}
}

/// Tests for the persisted-replay-cursor surfaces (pupa#103 relaunch catch-up)
/// and transport hardening for flaky edges (Cloudflare tunnel 5xx, mid-stream
/// socket death). Same serial scope as `Reattach` — shared `MockURLProtocol`.
extension AgentSessionTests {
@Suite("Replay cursor persistence + transport hardening", .serialized)
struct CursorPersistence {

    private static let sseHeaders: [String: String] = ["Content-Type": "text/event-stream"]

    private func makeClient() -> AgentClient {
        AgentClient(endpoint: URL(string: "http://mock.test/agent")!, session: makeMockSession())
    }

    private func freshSession(registry: ToolRegistry = ToolRegistry()) -> AgentSession {
        MockURLProtocol.reset()
        return AgentSession(client: makeClient(), registry: registry, threadId: "test-thread")
    }

    /// A normal 5-frame text round stamped with ids `0…4`.
    private static func idStampedTextRound() -> Data {
        sseBodyWithIds([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"hello"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
        ])
    }

    private static func emptyTailRound(startSeq: Int) -> Data {
        sseBodyWithIds([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"rT"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"rT"}"#,
        ], startSeq: startSeq)
    }

    private func drain(_ stream: AsyncThrowingStream<SessionEvent, Error>) async {
        do { for try await _ in stream {} } catch {}
    }

    // MARK: - Cursor exposure + seeding

    @Test("lastEventSeq is readable and tracks the highest streamed seq")
    func cursor_readableAfterTurn() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in (200, Self.idStampedTextRound(), Self.sseHeaders) }

        await drain(session.send("hi", context: { [] }))

        #expect(await session.lastEventSeq == 4)
    }

    @Test("seedReplayCursor arms reattach(): POSTs after_seq with the seeded value")
    func seededCursor_armsReattach() async throws {
        let session = freshSession()
        await session.seedReplayCursor(41)
        MockURLProtocol.responder = { _ in (200, Self.emptyTailRound(startSeq: 42), Self.sseHeaders) }

        await drain(session.reattach())

        #expect(MockURLProtocol.requestCount == 1)
        let input = try JSONDecoder().decode(RunAgentInput.self, from: MockURLProtocol.requestBodies[0])
        #expect(input.forwardedProps["command"]?["reattach"]?["after_seq"]?.intValue == 41)
        #expect(input.messages.isEmpty)
    }

    @Test("seedReplayCursor never regresses a cursor the session already advanced")
    func seededCursor_neverRegresses() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in (200, Self.idStampedTextRound(), Self.sseHeaders) }
        await drain(session.send("hi", context: { [] }))

        await session.seedReplayCursor(2)

        #expect(await session.lastEventSeq == 4)
    }

    // MARK: - Benign-empty reattach (204 / expired buffer)

    @Test("reattach() answered 204 (buffer gone) completes .produced — no droppedStream notice")
    func reattach_204_completesProduced() async throws {
        let session = freshSession()
        await session.seedReplayCursor(10)
        MockURLProtocol.responder = { _ in (204, Data(), [:]) }

        var outcomes: [CompletionOutcome] = []
        for try await ev in session.reattach() {
            if case .completed(let o) = ev { outcomes.append(o) }
        }

        #expect(outcomes == [.produced])
        #expect(MockURLProtocol.requestCount == 1)
    }

    // MARK: - Transport hardening

    @Test("mid-stream transport death surfaces as requestFailed, not a raw URLError")
    func midStreamDrop_wrappedAsRequestFailed() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.midStreamFailer = { _ in
            (prefix: sseBodyWithIds([#"{"type":"RUN_STARTED","threadId":"t","runId":"r"}"#]),
             error: URLError(.networkConnectionLost))
        }

        let client = makeClient()
        let input = RunAgentInput(threadId: "t", messages: [], tools: [], context: [])
        var caught: Error?
        do {
            for try await _ in client.runSequenced(input) {}
        } catch {
            caught = error
        }

        guard case AgentClientError.requestFailed? = caught else {
            Issue.record("expected .requestFailed, got \(String(describing: caught))")
            return
        }
    }

    @Test("HTTP 502 on the resume round re-attaches with backoff instead of failing the turn")
    func http5xxOnResume_reattaches() async throws {
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "addItem", description: "add", parameters: ["type": "object"]),
            handler: { _ in .object(["ok": .bool(true)]) }
        ))
        let session = freshSession(registry: registry)

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_A\",\"name\":\"addItem\",\"args\":{}}]}"#
        HardeningBodies.shared.reset()
        HardeningBodies.shared.a = sseBodyWithIds([                       // #1 send → cursor + interrupt
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        HardeningBodies.shared.c = sseBodyWithIds([                       // #3 reattach retry → settles
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r3"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"mf","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"mf","delta":"recovered"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"mf"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r3"}"#,
        ], startSeq: 3)
        MockURLProtocol.responder = { _ in
            switch MockURLProtocol.requestCount {
            case 1: return (200, HardeningBodies.shared.a!, Self.sseHeaders)
            case 2: return (502, Data("bad gateway".utf8), [:])           // tunnel edge error
            default: return (200, HardeningBodies.shared.c!, Self.sseHeaders)
            }
        }

        var completed = false
        for try await ev in session.send("hi", context: { [] }) {
            if case .completed = ev { completed = true }
        }

        #expect(completed)
        #expect(MockURLProtocol.requestCount == 3)
        let retry = try JSONDecoder().decode(RunAgentInput.self, from: MockURLProtocol.requestBodies[2])
        #expect(retry.forwardedProps["command"]?["reattach"] != nil)
    }

    @Test("reattach() whose first connect drops retries with backoff instead of erroring")
    func reattachConnectDrop_retries() async throws {
        let session = freshSession()
        await session.seedReplayCursor(7)
        MockURLProtocol.failer = { idx in idx == 1 ? URLError(.networkConnectionLost) : nil }
        MockURLProtocol.responder = { _ in (200, Self.emptyTailRound(startSeq: 8), Self.sseHeaders) }

        var completed = false
        var threw = false
        do {
            for try await ev in session.reattach() {
                if case .completed = ev { completed = true }
            }
        } catch {
            threw = true
        }

        #expect(completed)
        #expect(!threw)
        #expect(MockURLProtocol.requestCount == 2)
    }
}
}

// MARK: - Test helpers

/// Thread-safe holder for round-specific SSE bodies so the `@Sendable`
/// responder closure pulls them out without capturing locals.
private final class Bodies: @unchecked Sendable {
    static let shared = Bodies()
    var a: Data?
    var b: Data?
    var c: Data?
    func reset() { a = nil; b = nil; c = nil }
}

/// Tiny actor for thread-safe tool-dispatch counting.
private actor DispatchRecorder {
    private(set) var count: Int = 0
    func record(args: AnyJSON) { count += 1 }
}

/// Round-specific SSE bodies for the hardening suite (same pattern as `Bodies`).
private final class HardeningBodies: @unchecked Sendable {
    static let shared = HardeningBodies()
    var a: Data?
    var c: Data?
    func reset() { a = nil; c = nil }
}
