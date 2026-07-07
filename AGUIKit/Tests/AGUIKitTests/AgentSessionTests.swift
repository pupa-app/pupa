import Foundation
import Testing
@testable import AGUIKit

/// E2E tests for `AgentSession`'s interrupt-driven dispatch loop.
///
/// Frontend tool execution flows: the model emits tool_use blocks → the
/// backend pauses via `langgraph.interrupt(...)` → the AG-UI stream emits a
/// `CUSTOM(on_interrupt, value={"frontend_tool_calls": […]})` event →
/// AGUIKit dispatches each call locally and POSTs a follow-up round with
/// `forwardedProps.command.resume = {"tool_results": [...]}`. Backend tools
/// (e.g. `tavily_search`) execute inside the same stream and surface via
/// `TOOL_CALL_RESULT`; no extra POST.
///
/// `session.messages` only ever contains user (HumanMessage) entries —
/// the backend checkpoint is the source of truth for assistant + tool
/// history, and the chat UI builds its bubbles from `SessionEvent`s.
///
/// Tests are serialised because `MockURLProtocol` keeps responder state in
/// non-isolated static storage.
@Suite("AgentSession", .serialized)
struct AgentSessionTests {

    // MARK: - Helpers

    private func freshSession() -> AgentSession {
        MockURLProtocol.reset()
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        return AgentSession(
            client: client,
            registry: ToolRegistry(),
            threadId: "test-thread"
        )
    }

    private static let sseHeaders: [String: String] = ["Content-Type": "text/event-stream"]

    private static func textRoundBody(messageId: String, text: String) -> Data {
        sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"\#(messageId)","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"\#(messageId)","delta":"\#(text)"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"\#(messageId)"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
        ])
    }

    private static func emptyRoundBody() -> Data {
        sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
        ])
    }

    private func drain(_ stream: AsyncThrowingStream<SessionEvent, Error>) async {
        do {
            for try await _ in stream {}
        } catch {
            // Swallow — tests inspect `session.messages` after the fact.
        }
    }

    // MARK: - Happy path (e2e)

    @Test("Single-round text response settles on .completed with [user] in session.messages")
    func happyPath_singleRoundText() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in
            (200, Self.textRoundBody(messageId: "m1", text: "hello"), Self.sseHeaders)
        }

        await drain(session.send("hi", context: { [] }))

        let msgs = await session.messages
        // Only the user message lands locally — backend checkpoint owns
        // assistant + tool history.
        #expect(msgs.count == 1)
        #expect(msgs[0].role == .user)
        #expect(msgs[0].contentText == "hi")
        #expect(MockURLProtocol.requestCount == 1)
    }

    @Test("Two normal sends produce [user, user] in session.messages")
    func happyPath_twoSequentialSends() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in
            let n = MockURLProtocol.requestCount
            let body = n == 1
                ? Self.textRoundBody(messageId: "m1", text: "first reply")
                : Self.textRoundBody(messageId: "m2", text: "second reply")
            return (200, body, Self.sseHeaders)
        }

        await drain(session.send("first", context: { [] }))
        await drain(session.send("second", context: { [] }))

        let msgs = await session.messages
        #expect(msgs.count == 2)
        #expect(msgs.map(\.role) == [.user, .user])
        #expect(msgs[0].contentText == "first")
        #expect(msgs[1].contentText == "second")
    }

    // MARK: - Backend tools (in-stream)

    /// Backend tools execute inside the server-side agent loop and stream
    /// `TOOL_CALL_RESULT` back. AGUIKit must surface them through
    /// `.toolCallStarted` / `.toolCallFinished` so the UI shows progress,
    /// but it must NOT POST a follow-up round — the backend already handled
    /// the call.
    @Test("Backend-only tool call settles in one POST with .toolCallFinished carrying server result")
    func backendTool_inStream_oneRound_yieldsServerResult() async throws {
        let session = freshSession()
        let resultJSON = #"{\"answer\":\"42\",\"sources\":[\"https://example.com\"]}"#
        let round1 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"searching"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
            #"{"type":"TOOL_CALL_START","toolCallId":"call_be","toolCallName":"tavily_search"}"#,
            #"{"type":"TOOL_CALL_ARGS","toolCallId":"call_be","delta":"{\"query\":\"x\"}"}"#,
            #"{"type":"TOOL_CALL_END","toolCallId":"call_be"}"#,
            #"{"type":"TOOL_CALL_RESULT","messageId":"tr1","toolCallId":"call_be","content":"\#(resultJSON)","role":"tool"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        MockURLProtocol.responder = { _ in (200, round1, Self.sseHeaders) }

        var startedSeen = 0
        var finishedPayload: (id: String, name: String, arguments: AnyJSON, result: AnyJSON?)?
        var completed = false
        for try await ev in session.send("search", context: { [] }) {
            switch ev {
            case .toolCallStarted(_, let name) where name == "tavily_search":
                startedSeen += 1
            case .toolCallFinished(let id, let name, let args, let result):
                if name == "tavily_search" {
                    finishedPayload = (id, name, args, result)
                }
            case .completed:
                completed = true
            default:
                break
            }
        }

        #expect(startedSeen == 1)
        let finished = try #require(finishedPayload)
        #expect(finished.id == "call_be")
        #expect(finished.arguments["query"]?.stringValue == "x")
        let result = try #require(finished.result)
        #expect(result["answer"]?.stringValue == "42")
        #expect(result["sources"]?.arrayValue?.first?.stringValue == "https://example.com")
        #expect(completed)
        // Exactly one POST — no phantom round 2.
        #expect(MockURLProtocol.requestCount == 1)
    }

    // MARK: - Frontend interrupt dispatch

    /// `CUSTOM(on_interrupt, value={"frontend_tool_calls": […]})` triggers
    /// the new interrupt-driven dispatch loop: AGUIKit runs every call
    /// through the local registry, then POSTs a resume round whose
    /// `forwardedProps.command.resume.tool_results` carries the per-call
    /// result. Wire shape and submission order are pinned here.
    @Test("frontend_tool_calls interrupt → dispatch → resume POSTs tool_results in submission order")
    func frontendInterrupt_dispatchesAndPostsResume() async throws {
        MockURLProtocol.reset()
        let recorder = DispatchRecorder()
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "addItem", description: "add", parameters: ["type": "object"]),
            handler: { args in
                await recorder.record(args: args)
                let item = args["item"]?["name"]?.stringValue ?? ""
                return .object(["ok": .bool(true), "added": .string(item)])
            }
        ))
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread")

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_A\",\"name\":\"addItem\",\"args\":{\"item\":{\"name\":\"apple\"}}},{\"id\":\"call_B\",\"name\":\"addItem\",\"args\":{\"item\":{\"name\":\"pear\"}}}]}"#
        let round1 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            #"{"type":"TOOL_CALL_START","toolCallId":"call_A","toolCallName":"addItem"}"#,
            #"{"type":"TOOL_CALL_ARGS","toolCallId":"call_A","delta":"{\"item\":{\"name\":\"apple\"}}"}"#,
            #"{"type":"TOOL_CALL_END","toolCallId":"call_A"}"#,
            #"{"type":"TOOL_CALL_START","toolCallId":"call_B","toolCallName":"addItem"}"#,
            #"{"type":"TOOL_CALL_ARGS","toolCallId":"call_B","delta":"{\"item\":{\"name\":\"pear\"}}"}"#,
            #"{"type":"TOOL_CALL_END","toolCallId":"call_B"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        let round2 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"mfinal","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"mfinal","delta":"both added"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"mfinal"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ])
        TestBodies.shared.round1 = round1
        TestBodies.shared.round2 = round2
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? TestBodies.shared.round1!
                : TestBodies.shared.round2!
            return (200, body, Self.sseHeaders)
        }

        var finishedIds: [String] = []
        var completed = false
        for try await ev in session.send("add two", context: { [] }) {
            switch ev {
            case .toolCallFinished(let id, _, _, _):
                finishedIds.append(id)
            case .completed:
                completed = true
            default:
                break
            }
        }

        // Each frontend tool ran once via the local registry.
        #expect(await recorder.count == 2)
        // `.toolCallFinished` fired for each call in submission order.
        #expect(finishedIds == ["call_A", "call_B"])
        #expect(completed)

        // Two HTTP POSTs: the initial send and the resume.
        #expect(MockURLProtocol.requestCount == 2)

        // The resume body's forwardedProps carries `tool_results` matching
        // submission order with the handler's JSON-encoded return values.
        let resumeBody = MockURLProtocol.requestBodies[1]
        let input = try JSONDecoder().decode(RunAgentInput.self, from: resumeBody)
        let results = try #require(input.forwardedProps["command"]?["resume"]?["tool_results"]?.arrayValue)
        #expect(results.count == 2)
        #expect(results[0]["toolCallId"]?.stringValue == "call_A")
        #expect(results[1]["toolCallId"]?.stringValue == "call_B")
        // `content` is a JSON-encoded string per the AG-UI wire convention.
        let firstContent = try #require(results[0]["content"]?.stringValue)
        #expect(firstContent.contains("apple"))
        let secondContent = try #require(results[1]["content"]?.stringValue)
        #expect(secondContent.contains("pear"))

        // The local messages array still only carries the user message.
        let msgs = await session.messages
        #expect(msgs.count == 1)
        #expect(msgs[0].role == .user)
    }

    /// Two `parallelSafe` handlers in the same interrupt batch must run
    /// concurrently (their execution windows overlap), but their results
    /// must still be packaged in submission order so the resume POST
    /// matches the model's tool_call order.
    @Test("parallelSafe handlers in one interrupt run concurrently; results stay in submission order")
    func parallelSafeFrontendTools_runConcurrently_resumeOrderPreserved() async throws {
        MockURLProtocol.reset()
        let timeline = OverlapRecorder()
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "slowOp", description: "slow", parameters: ["type": "object"]),
            parallelSafe: true,
            handler: { args in
                let tag = args["tag"]?.stringValue ?? "?"
                await timeline.start(tag)
                try? await Task.sleep(nanoseconds: 200_000_000)
                await timeline.end(tag)
                return .object(["ok": .bool(true), "tag": .string(tag)])
            }
        ))
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "fastOp", description: "fast", parameters: ["type": "object"]),
            parallelSafe: true,
            handler: { args in
                let tag = args["tag"]?.stringValue ?? "?"
                await timeline.start(tag)
                try? await Task.sleep(nanoseconds: 50_000_000)
                await timeline.end(tag)
                return .object(["ok": .bool(true), "tag": .string(tag)])
            }
        ))
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread")

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_A\",\"name\":\"slowOp\",\"args\":{\"tag\":\"A\"}},{\"id\":\"call_B\",\"name\":\"fastOp\",\"args\":{\"tag\":\"B\"}}]}"#
        let round1 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        let round2 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"mfinal","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"mfinal","delta":"both done"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"mfinal"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ])
        TestBodies.shared.round1 = round1
        TestBodies.shared.round2 = round2
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? TestBodies.shared.round1!
                : TestBodies.shared.round2!
            return (200, body, Self.sseHeaders)
        }

        await drain(session.send("go", context: { [] }))

        let starts = await timeline.starts
        let ends = await timeline.ends
        let aEnd = try #require(ends["A"])
        let bStart = try #require(starts["B"])
        #expect(
            bStart < aEnd,
            "fastOp(B) must start before slowOp(A) ends — parallel dispatch regressed?"
        )

        // The resume body's tool_results stay in submission order even
        // though fastOp finished first.
        let resumeBody = MockURLProtocol.requestBodies[1]
        let input = try JSONDecoder().decode(RunAgentInput.self, from: resumeBody)
        let results = try #require(input.forwardedProps["command"]?["resume"]?["tool_results"]?.arrayValue)
        #expect(results.map { $0["toolCallId"]?.stringValue } == ["call_A", "call_B"])
    }

    /// `.toolCallStarted` fires when the wire's `TOOL_CALL_START` arrives,
    /// well before the interrupt resolves. `.toolCallFinished` follows
    /// after the local handler returns. The order must be preserved end
    /// to end so chat UIs can pair their spinner with a checkmark.
    @Test("toolCallStarted precedes toolCallFinished even when dispatch happens via interrupt")
    func liveProgressEvents_orderingPreservedAcrossInterrupt() async throws {
        MockURLProtocol.reset()
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "echo", description: "echo", parameters: ["type": "object"]),
            handler: { args in .object(["ok": .bool(true), "echoed": args]) }
        ))
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread")

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_1\",\"name\":\"echo\",\"args\":{\"x\":1}}]}"#
        let round1 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            #"{"type":"TOOL_CALL_START","toolCallId":"call_1","toolCallName":"echo"}"#,
            #"{"type":"TOOL_CALL_ARGS","toolCallId":"call_1","delta":"{\"x\":1}"}"#,
            #"{"type":"TOOL_CALL_END","toolCallId":"call_1"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        let round2 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"mfinal","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"mfinal","delta":"done"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"mfinal"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ])
        TestBodies.shared.round1 = round1
        TestBodies.shared.round2 = round2
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? TestBodies.shared.round1!
                : TestBodies.shared.round2!
            return (200, body, Self.sseHeaders)
        }

        var trace: [String] = []
        var finishedResult: AnyJSON?
        for try await ev in session.send("go", context: { [] }) {
            switch ev {
            case .toolCallStarted:
                trace.append("started")
            case .toolCallFinished(_, _, _, let result):
                trace.append("finished")
                finishedResult = result
            case .roundFinished:
                trace.append("roundFinished")
            case .assistantMessageStart:
                trace.append("assistantStart")
            case .completed:
                trace.append("completed")
            default:
                break
            }
        }

        let startedIdx = try #require(trace.firstIndex(of: "started"))
        let finishedIdx = try #require(trace.firstIndex(of: "finished"))
        let firstRoundFinishedIdx = try #require(trace.firstIndex(of: "roundFinished"))
        let assistantStartIdx = try #require(trace.firstIndex(of: "assistantStart"))
        let completedIdx = try #require(trace.firstIndex(of: "completed"))

        #expect(startedIdx < firstRoundFinishedIdx, "trace=\(trace)")
        #expect(firstRoundFinishedIdx < finishedIdx, "trace=\(trace)")
        #expect(finishedIdx < assistantStartIdx, "trace=\(trace)")
        #expect(assistantStartIdx < completedIdx, "trace=\(trace)")

        let result = try #require(finishedResult)
        #expect(result["ok"]?.boolValue == true)
        #expect(result["echoed"]?["x"]?.intValue == 1)
    }

    /// When the backend asks us to dispatch a tool the local registry
    /// doesn't know about, the session must NOT deadlock. It synthesises
    /// a structured failure result so the resume payload still completes.
    @Test("Unknown frontend tool returns a structured failure in the resume payload")
    func unknownFrontendTool_returnsStructuredFailure() async throws {
        MockURLProtocol.reset()
        // Empty registry — the model is asking for a tool we don't have.
        let registry = ToolRegistry()
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread")

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_X\",\"name\":\"nopeNotRegistered\",\"args\":{}}]}"#
        let round1 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        let round2 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"mfinal","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"mfinal","delta":"continued"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"mfinal"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ])
        TestBodies.shared.round1 = round1
        TestBodies.shared.round2 = round2
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? TestBodies.shared.round1!
                : TestBodies.shared.round2!
            return (200, body, Self.sseHeaders)
        }

        await drain(session.send("go", context: { [] }))

        let resumeBody = MockURLProtocol.requestBodies[1]
        let input = try JSONDecoder().decode(RunAgentInput.self, from: resumeBody)
        let results = try #require(input.forwardedProps["command"]?["resume"]?["tool_results"]?.arrayValue)
        let content = try #require(results[0]["content"]?.stringValue)
        #expect(content.contains("not registered"))
    }

    // MARK: - Orphan user replacement (regression for duplicate-spiral bug)

    @Test("Orphan user (HTTP error on first send) is replaced, not stacked")
    func orphan_replacedAfterHTTPError() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in
            if MockURLProtocol.requestCount == 1 {
                return (500, Data("internal error".utf8), [:])
            }
            return (200, Self.textRoundBody(messageId: "m1", text: "ok now"), Self.sseHeaders)
        }

        await drain(session.send("first", context: { [] }))
        let mid = await session.messages
        #expect(mid.count == 1)
        #expect(mid[0].contentText == "first")

        await drain(session.send("second", context: { [] }))

        let final = await session.messages
        #expect(final.count == 1, "Replaced orphan, not stacked")
        #expect(final[0].contentText == "second")
    }

    @Test("Orphan user (empty round) is replaced on next send")
    func orphan_replacedAfterEmptyRound() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? Self.emptyRoundBody()
                : Self.textRoundBody(messageId: "m1", text: "now i answer")
            return (200, body, Self.sseHeaders)
        }

        await drain(session.send("first", context: { [] }))
        await drain(session.send("second", context: { [] }))

        let final = await session.messages
        #expect(final.count == 1)
        #expect(final[0].contentText == "second")
    }

    @Test("Repeated failures don't accumulate orphan user messages")
    func orphan_replacedAcrossRepeatedFailures() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in
            if MockURLProtocol.requestCount < 4 {
                return (500, Data("boom".utf8), [:])
            }
            return (200, Self.textRoundBody(messageId: "ok", text: "finally"), Self.sseHeaders)
        }

        await drain(session.send("a", context: { [] }))
        await drain(session.send("b", context: { [] }))
        await drain(session.send("c", context: { [] }))
        await drain(session.send("d", context: { [] }))

        let msgs = await session.messages
        #expect(msgs.count == 1, "Four user sends collapse to one — only the last survives")
        #expect(msgs[0].contentText == "d")
    }

    // MARK: - Tool filter

    /// Mid-round refresh contract. `toolFilter` is re-evaluated at the top
    /// of every round so the host can widen / narrow the advertised set
    /// across resumes (e.g. a kind-gated tool becomes available after the
    /// agent's `addComponent` call mutates state).
    @Test("toolFilter is re-evaluated on every round")
    func toolFilter_recomputesPerRound() async throws {
        MockURLProtocol.reset()
        let registry = ToolRegistry()
        let noopHandler: @Sendable (AnyJSON) async throws -> AnyJSON = { _ in .object(["ok": .bool(true)]) }
        for name in ["alpha", "beta", "gamma"] {
            registry.register(ClientTool(
                descriptor: ToolDescriptor(name: name, description: name, parameters: ["type": "object"]),
                handler: noopHandler
            ))
        }
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread")

        // Round 1 pauses on a frontend interrupt asking for `alpha`. Round
        // 2 is the resume — the filter widens to include `gamma`.
        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_1\",\"name\":\"alpha\",\"args\":{}}]}"#
        let round1 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        let round2 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"final","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"final","delta":"done"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"final"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ])
        TestBodies.shared.round1 = round1
        TestBodies.shared.round2 = round2
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? TestBodies.shared.round1!
                : TestBodies.shared.round2!
            return (200, body, Self.sseHeaders)
        }

        actor FilterState {
            var calls = 0
            func next() -> Set<String> {
                calls += 1
                return calls == 1 ? ["alpha"] : ["alpha", "gamma"]
            }
        }
        let state = FilterState()

        await drain(session.send(
            "go",
            context: { [] },
            toolFilter: { await state.next() }
        ))

        #expect(MockURLProtocol.requestCount == 2)
        let filterCalls = await state.calls
        // Three calls: top of round 1, after-dispatch (to build the
        // resume payload's `tools_after_round`), top of round 2.
        #expect(filterCalls == 3)

        let r1 = try JSONDecoder().decode(RunAgentInput.self, from: MockURLProtocol.requestBodies[0])
        let r2 = try JSONDecoder().decode(RunAgentInput.self, from: MockURLProtocol.requestBodies[1])
        #expect(Set(r1.tools.map(\.name)) == ["alpha"])
        #expect(Set(r2.tools.map(\.name)) == ["alpha", "gamma"])
    }

    /// Mid-turn refresh side-channel. `ag_ui_langgraph` discards
    /// `RunAgentInput.tools` on the resume branch, so the iOS client
    /// mirrors the widened descriptor list inside
    /// `forwardedProps.command.resume.tools_after_round`. The backend's
    /// `CopilotKitMiddlewareWithFrontendInterrupt` reads from there to
    /// refresh `state["copilotkit"]["actions"]` before the model is
    /// re-invoked.
    @Test("resume POST embeds the post-dispatch tool descriptors in tools_after_round")
    func resumePayload_carriesToolsAfterRound() async throws {
        MockURLProtocol.reset()
        let registry = ToolRegistry()
        let alphaHandler: @Sendable (AnyJSON) async throws -> AnyJSON = { _ in .object(["ok": .bool(true)]) }
        for name in ["alpha", "beta", "gamma"] {
            registry.register(ClientTool(
                descriptor: ToolDescriptor(name: name, description: name, parameters: ["type": "object"]),
                handler: alphaHandler
            ))
        }
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread")

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_1\",\"name\":\"alpha\",\"args\":{}}]}"#
        let round1 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        let round2 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"final","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"final","delta":"done"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"final"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ])
        TestBodies.shared.round1 = round1
        TestBodies.shared.round2 = round2
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? TestBodies.shared.round1!
                : TestBodies.shared.round2!
            return (200, body, Self.sseHeaders)
        }

        actor FilterState {
            var calls = 0
            func next() -> Set<String> {
                calls += 1
                // Filter widens after dispatch: round 1 advertised `alpha`,
                // post-dispatch (and round 2) advertises `alpha + gamma`.
                return calls == 1 ? ["alpha"] : ["alpha", "gamma"]
            }
        }
        let state = FilterState()

        await drain(session.send(
            "go",
            context: { [] },
            toolFilter: { await state.next() }
        ))

        #expect(MockURLProtocol.requestCount == 2)
        #expect(MockURLProtocol.requestBodies.count >= 2)
        let r2 = try JSONDecoder().decode(RunAgentInput.self, from: MockURLProtocol.requestBodies[1])

        // Pull tools_after_round out of forwardedProps.command.resume.
        let resume = try #require(r2.forwardedProps["command"]?["resume"]?.objectValue)
        let toolsAfterRound = try #require(resume["tools_after_round"]?.arrayValue)
        let names: [String] = toolsAfterRound.compactMap { $0["name"]?.stringValue }
        #expect(Set(names) == ["alpha", "gamma"],
                "resume payload's tools_after_round should mirror the post-dispatch filter, got \(names)")

        // Each descriptor carries name/description/parameters so the
        // backend can write them straight into `copilotkit.actions`.
        let alpha = try #require(toolsAfterRound.first { $0["name"]?.stringValue == "alpha" }?.objectValue)
        #expect(alpha["description"]?.stringValue == "alpha")
        #expect(alpha["parameters"] != nil)
    }

    @Test("toolFilter restricts the tools sent in RunAgentInput")
    func toolFilter_restrictsAdvertisedDescriptors() async throws {
        MockURLProtocol.reset()
        let registry = ToolRegistry()
        let noopHandler: @Sendable (AnyJSON) async throws -> AnyJSON = { _ in .object([:]) }
        for name in ["alpha", "beta", "gamma"] {
            registry.register(ClientTool(
                descriptor: ToolDescriptor(name: name, description: "x", parameters: .object([:])),
                handler: noopHandler
            ))
        }
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread")

        MockURLProtocol.responder = { _ in
            (200, Self.textRoundBody(messageId: "m1", text: "ok"), Self.sseHeaders)
        }

        await drain(session.send("hi", context: { [] }, toolFilter: { ["alpha", "gamma"] }))

        let body = try #require(MockURLProtocol.lastRequestBody)
        let input = try JSONDecoder().decode(RunAgentInput.self, from: body)
        #expect(Set(input.tools.map(\.name)) == ["alpha", "gamma"])
    }

    @Test("Without toolFilter, all registered descriptors are advertised")
    func toolFilter_nilSendsAll() async throws {
        MockURLProtocol.reset()
        let registry = ToolRegistry()
        let noopHandler: @Sendable (AnyJSON) async throws -> AnyJSON = { _ in .object([:]) }
        for name in ["alpha", "beta", "gamma"] {
            registry.register(ClientTool(
                descriptor: ToolDescriptor(name: name, description: name, parameters: .object([:])),
                handler: noopHandler
            ))
        }
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread")

        MockURLProtocol.responder = { _ in
            (200, Self.textRoundBody(messageId: "m1", text: "ok"), Self.sseHeaders)
        }

        await drain(session.send("hi", context: { [] }))

        let body = try #require(MockURLProtocol.lastRequestBody)
        let input = try JSONDecoder().decode(RunAgentInput.self, from: body)
        #expect(Set(input.tools.map(\.name)) == ["alpha", "beta", "gamma"])
    }

    // MARK: - state provider (RunAgentInput.state)

    @Test("send(state:) forwards the provider's payload on RunAgentInput.state")
    func state_providerForwardsOnWire() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in
            (200, Self.textRoundBody(messageId: "m1", text: "ok"), Self.sseHeaders)
        }

        await drain(session.send(
            "hi",
            context: { [] },
            state: {
                .object(["disabled_tools": .array([.string("tavily_search")])])
            }
        ))

        let body = try #require(MockURLProtocol.lastRequestBody)
        let input = try JSONDecoder().decode(RunAgentInput.self, from: body)
        let disabled = input.state["disabled_tools"]?.arrayValue?.compactMap(\.stringValue)
        #expect(disabled == ["tavily_search"])
    }

    @Test("Omitted state provider sends RunAgentInput.state = null")
    func state_omittedDefaultsToNull() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in
            (200, Self.textRoundBody(messageId: "m1", text: "ok"), Self.sseHeaders)
        }

        await drain(session.send("hi", context: { [] }))

        let body = try #require(MockURLProtocol.lastRequestBody)
        let input = try JSONDecoder().decode(RunAgentInput.self, from: body)
        if case .null = input.state {
            // pass
        } else {
            Issue.record("expected RunAgentInput.state == .null, got \(input.state)")
        }
    }

    // MARK: - Completion outcome (silent-stop detection)

    /// Collect the final `.completed(outcome)` from a stream, swallowing errors.
    private func lastCompletion(
        _ stream: AsyncThrowingStream<SessionEvent, Error>
    ) async -> CompletionOutcome? {
        var outcome: CompletionOutcome?
        do {
            for try await ev in stream {
                if case .completed(let o) = ev { outcome = o }
            }
        } catch {
            // Tests inspect the last-seen outcome, if any.
        }
        return outcome
    }

    @Test("A round with assistant text settles as .completed(.produced)")
    func completion_textRound_produced() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in
            (200, Self.textRoundBody(messageId: "m1", text: "hello"), Self.sseHeaders)
        }
        let outcome = await lastCompletion(session.send("hi", context: { [] }))
        #expect(outcome == .produced)
    }

    @Test("RUN_FINISHED with no text settles as .completed(.silent(.emptyTurn))")
    func completion_emptyRound_silentEmptyTurn() async throws {
        let session = freshSession()
        MockURLProtocol.responder = { _ in
            (200, Self.emptyRoundBody(), Self.sseHeaders)
        }
        let outcome = await lastCompletion(session.send("hi", context: { [] }))
        #expect(outcome == .silent(.emptyTurn))
    }

    @Test("Clean EOF with no RUN_FINISHED settles as .completed(.silent(.droppedStream))")
    func completion_noRunFinished_silentDroppedStream() async throws {
        let session = freshSession()
        // Stream ends (clean EOF) after RUN_STARTED — no RUN_FINISHED, no text.
        let body = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
        ])
        MockURLProtocol.responder = { _ in (200, body, Self.sseHeaders) }
        let outcome = await lastCompletion(session.send("hi", context: { [] }))
        #expect(outcome == .silent(.droppedStream))
    }

    @Test("Undecodable on_interrupt settles as .completed(.silent(.backend)) — never a clean silent stop")
    func completion_undecodableInterrupt_silentBackend() async throws {
        let session = freshSession()
        // on_interrupt with an empty frontend_tool_calls list → decode returns
        // nil → no dispatch. Must surface as a notice, not a clean settle.
        let interruptValue = #"{\"frontend_tool_calls\":[]}"#
        let body = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
        ])
        MockURLProtocol.responder = { _ in (200, body, Self.sseHeaders) }
        let outcome = await lastCompletion(session.send("hi", context: { [] }))
        guard case .silent(.backend) = outcome else {
            Issue.record("expected .silent(.backend), got \(String(describing: outcome))")
            return
        }
    }

    // MARK: - Dropped-interrupt self-heal (ag-ui-langgraph tasks[0] emit bug)

    @Test("Frontend tool with no on_interrupt self-heals via a resume-less recovery re-POST")
    func droppedInterrupt_selfHeals_viaRecoveryRePost() async throws {
        MockURLProtocol.reset()
        let recorder = DispatchRecorder()
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "renderTracker", description: "render", parameters: ["type": "object"]),
            handler: { _ in
                await recorder.record(args: .null)
                return .object(["ok": .bool(true)])
            }
        ))
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread")

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_A\",\"name\":\"renderTracker\",\"args\":{}}]}"#
        // Round 1: the model narrates AND calls renderTracker, but the backend
        // DROPS the on_interrupt (the `tasks[0]` emit bug) — looks like a clean
        // finish. Round 2: the resume-less recovery re-POST; the backend's
        // recovery path re-emits the parked on_interrupt. Round 3: resume → text.
        TestBodies.shared.round1 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"rendering now"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
            #"{"type":"TOOL_CALL_START","toolCallId":"call_A","toolCallName":"renderTracker"}"#,
            #"{"type":"TOOL_CALL_ARGS","toolCallId":"call_A","delta":"{}"}"#,
            #"{"type":"TOOL_CALL_END","toolCallId":"call_A"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        TestBodies.shared.round2 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ])
        TestBodies.shared.round3 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r3"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"m2","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m2","delta":"done"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"m2"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r3"}"#,
        ])
        MockURLProtocol.responder = { _ in
            let body: Data
            switch MockURLProtocol.requestCount {
            case 1: body = TestBodies.shared.round1!
            case 2: body = TestBodies.shared.round2!
            default: body = TestBodies.shared.round3!
            }
            return (200, body, Self.sseHeaders)
        }

        let outcome = await lastCompletion(session.send("render a tracker", context: { [] }))

        // The tool ran once (after recovery re-emitted the interrupt) and the
        // turn settled cleanly on the resume round's text.
        #expect(await recorder.count == 1)
        #expect(outcome == .produced)
        // Three POSTs: initial send, resume-less recovery re-POST, resume.
        #expect(MockURLProtocol.requestCount == 3)

        // The recovery re-POST (round 2) carries NO command.resume — a plain
        // continuation that triggers the backend's recovery path.
        let recoveryInput = try JSONDecoder().decode(RunAgentInput.self, from: MockURLProtocol.requestBodies[1])
        #expect(recoveryInput.forwardedProps["command"]?["resume"] == nil)
        // The resume POST (round 3) DOES carry tool_results for the dispatched call.
        let resumeInput = try JSONDecoder().decode(RunAgentInput.self, from: MockURLProtocol.requestBodies[2])
        let results = try #require(resumeInput.forwardedProps["command"]?["resume"]?["tool_results"]?.arrayValue)
        #expect(results.count == 1)
    }

    @Test("A frontend tool that never gets an interrupt settles as .silent(.droppedInterrupt) after bounded retries")
    func droppedInterrupt_recoveryExhausted_settlesDroppedInterrupt() async throws {
        MockURLProtocol.reset()
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "renderTracker", description: "render", parameters: ["type": "object"]),
            handler: { _ in .object(["ok": .bool(true)]) }
        ))
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread")

        // Every round calls renderTracker with NO on_interrupt — the backend
        // recovery never surfaces one. The self-heal must give up after its
        // bounded retries and surface a notice rather than loop forever.
        let body = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
            #"{"type":"TOOL_CALL_START","toolCallId":"call_A","toolCallName":"renderTracker"}"#,
            #"{"type":"TOOL_CALL_ARGS","toolCallId":"call_A","delta":"{}"}"#,
            #"{"type":"TOOL_CALL_END","toolCallId":"call_A"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
        ])
        MockURLProtocol.responder = { _ in (200, body, Self.sseHeaders) }

        let outcome = await lastCompletion(session.send("render a tracker", context: { [] }))
        #expect(outcome == .silent(.droppedInterrupt))
        // Initial send + 2 bounded recovery re-POSTs = 3 POSTs, then it stops.
        #expect(MockURLProtocol.requestCount == 3)
    }

    @Test("Text in an early round keeps the turn .produced even if a later round settles empty")
    func completion_textThenEmptySettle_produced() async throws {
        MockURLProtocol.reset()
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "addItem", description: "add", parameters: ["type": "object"]),
            handler: { _ in .object(["ok": .bool(true)]) }
        ))
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread")

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_A\",\"name\":\"addItem\",\"args\":{}}]}"#
        // Round 1: narrates text AND interrupts. Round 2: settles empty.
        TestBodies.shared.round1 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"working"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        TestBodies.shared.round2 = Self.emptyRoundBody()
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? TestBodies.shared.round1!
                : TestBodies.shared.round2!
            return (200, body, Self.sseHeaders)
        }
        let outcome = await lastCompletion(session.send("go", context: { [] }))
        #expect(outcome == .produced)
    }

    /// Regression for the strand bug: an interrupt landing on the FINAL allowed
    /// round must still POST its resume (unpark the backend) rather than exiting
    /// silently. With `maxRounds == 1` the old loop dropped the resume.
    @Test("Interrupt on the final round still POSTs its resume (no stranded park)")
    func completion_interruptAtCap_stillResumes() async throws {
        MockURLProtocol.reset()
        let recorder = DispatchRecorder()
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "addItem", description: "add", parameters: ["type": "object"]),
            handler: { args in await recorder.record(args: args); return .object(["ok": .bool(true)]) }
        ))
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread", maxRounds: 1)

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_A\",\"name\":\"addItem\",\"args\":{}}]}"#
        TestBodies.shared.round1 = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        // The forced final resume round settles empty (cap already hit).
        TestBodies.shared.round2 = Self.emptyRoundBody()
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? TestBodies.shared.round1!
                : TestBodies.shared.round2!
            return (200, body, Self.sseHeaders)
        }

        let outcome = await lastCompletion(session.send("go", context: { [] }))
        // The tool ran and, crucially, the resume POST was sent (2 requests) —
        // the backend park is resolved, not stranded.
        #expect(await recorder.count == 1)
        #expect(MockURLProtocol.requestCount == 2)
        #expect(outcome == .silent(.maxRounds))
    }

    /// `maxRounds: nil` removes the breaker: the turn runs until the backend
    /// settles, dispatching every interrupt along the way, and never trips the
    /// `.maxRounds` notice.
    @Test("maxRounds nil runs unbounded — every interrupt resumes, settles normally")
    func completion_unlimitedCap_resumesAllInterrupts() async throws {
        MockURLProtocol.reset()
        let recorder = DispatchRecorder()
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "addItem", description: "add", parameters: ["type": "object"]),
            handler: { args in await recorder.record(args: args); return .object(["ok": .bool(true)]) }
        ))
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!,
            session: makeMockSession()
        )
        let session = AgentSession(client: client, registry: registry, threadId: "test-thread", maxRounds: nil)

        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"c\",\"name\":\"addItem\",\"args\":{}}]}"#
        let interruptBody = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
        ])
        // Two interrupt rounds (well past the old default cap of 8 would be fine
        // too), then a text settle. With no cap all three POSTs go out.
        TestBodies.shared.round1 = interruptBody
        TestBodies.shared.round2 = interruptBody
        TestBodies.shared.round3 = Self.textRoundBody(messageId: "mf", text: "done")
        MockURLProtocol.responder = { _ in
            let n = MockURLProtocol.requestCount
            let body = n == 1 ? TestBodies.shared.round1!
                : (n == 2 ? TestBodies.shared.round2! : TestBodies.shared.round3!)
            return (200, body, Self.sseHeaders)
        }

        let outcome = await lastCompletion(session.send("go", context: { [] }))
        #expect(await recorder.count == 2)          // both interrupts dispatched
        #expect(MockURLProtocol.requestCount == 3)  // 2 interrupts + final text
        #expect(outcome == .produced)               // no .maxRounds trip
    }
}

// MARK: - Test helpers

/// Records handler start/end times keyed by a caller-supplied tag. Used by
/// the parallel-dispatch test to assert that two handlers' execution
/// windows overlap.
private actor OverlapRecorder {
    private(set) var starts: [String: Date] = [:]
    private(set) var ends: [String: Date] = [:]

    func start(_ tag: String) { starts[tag] = Date() }
    func end(_ tag: String) { ends[tag] = Date() }
}

/// Tiny actor for thread-safe tool-dispatch counting.
private actor DispatchRecorder {
    private(set) var count: Int = 0
    private(set) var args: [AnyJSON] = []

    func record(args: AnyJSON) {
        self.count += 1
        self.args.append(args)
    }
}

/// Holder for round-specific SSE bodies so the `@Sendable` responder
/// closure can pull them out without capturing locals.
private final class TestBodies: @unchecked Sendable {
    static let shared = TestBodies()
    var round1: Data?
    var round2: Data?
    var round3: Data?
}
