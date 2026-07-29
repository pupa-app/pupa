import Foundation
import Testing
@testable import AGUIKit

/// Client liveness heartbeat for parked frontend tools (pupa-backend#82).
///
/// While a frontend tool dispatch is in flight the backend's `claim_call` sits
/// parked with no open socket; the session now POSTs
/// `command.keepalive {state}` every `keepaliveInterval` so a dead app fails
/// fast server-side while a slow tool survives. Backgrounding sends one
/// explicit `state: "background"` notice and pauses pinging (the backend falls
/// back to its absolute wall). Same serial scope as the other session suites.
extension AgentSessionTests {
@Suite("Frontend-tool keepalive heartbeat", .serialized)
struct Keepalive {

    private static let sseHeaders: [String: String] = ["Content-Type": "text/event-stream"]

    private func makeSession(
        registry: ToolRegistry,
        keepaliveInterval: TimeInterval
    ) -> AgentSession {
        MockURLProtocol.reset()
        let client = AgentClient(
            endpoint: URL(string: "http://mock.test/agent")!, session: makeMockSession())
        return AgentSession(
            client: client, registry: registry, threadId: "test-thread",
            keepaliveInterval: keepaliveInterval)
    }

    /// True when a captured POST body is a keepalive ping; returns its state.
    private static func keepaliveState(_ body: Data) -> String? {
        guard let input = try? JSONDecoder().decode(RunAgentInput.self, from: body) else {
            return nil
        }
        return input.forwardedProps["command"]?["keepalive"]?["state"]?.stringValue
    }

    /// Responder that answers keepalive pings 204 and everything else with the
    /// canned SSE bodies: round 1 = interrupt, resume = settle.
    private static func installResponder() {
        let interruptValue = #"{\"frontend_tool_calls\":[{\"id\":\"call_A\",\"name\":\"slowTool\",\"args\":{}}]}"#
        let round1 = sseBodyWithIds([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r1"}"#,
            "{\"type\":\"CUSTOM\",\"name\":\"on_interrupt\",\"value\":\"\(interruptValue)\"}",
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r1"}"#,
        ])
        let settle = sseBodyWithIds([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"mf","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"mf","delta":"done"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"mf"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ], startSeq: 3)
        MockURLProtocol.responder = { req in
            let body = MockURLProtocol.requestBodies.last ?? Data()
            if Self.keepaliveState(body) != nil { return (204, Data(), [:]) }
            let isResume = (try? JSONDecoder().decode(RunAgentInput.self, from: body))
                .map { $0.forwardedProps["command"]?["resume"] != nil } ?? false
            return (200, isResume ? settle : round1, Self.sseHeaders)
        }
    }

    private func slowRegistry(sleepNanos: UInt64) -> ToolRegistry {
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "slowTool", description: "s", parameters: ["type": "object"]),
            handler: { _ in
                try? await Task.sleep(nanoseconds: sleepNanos)
                return .object(["ok": .bool(true)])
            }
        ))
        return registry
    }

    @Test("a slow frontend-tool dispatch emits periodic keepalive pings")
    func slowDispatch_emitsKeepalives() async throws {
        let session = makeSession(
            registry: slowRegistry(sleepNanos: 250_000_000), keepaliveInterval: 0.05)
        Self.installResponder()

        for try await _ in session.send("go", context: { [] }) {}

        let states = MockURLProtocol.requestBodies.compactMap(Self.keepaliveState)
        #expect(states.count >= 2, "expected periodic pings during a 0.25s dispatch, got \(states)")
        #expect(states.allSatisfy { $0 == "active" })
        // Pings carry an empty body apart from the command.
        let firstKA = MockURLProtocol.requestBodies.first { Self.keepaliveState($0) != nil }
        if let firstKA, let input = try? JSONDecoder().decode(RunAgentInput.self, from: firstKA) {
            #expect(input.messages.isEmpty)
            #expect(input.tools.isEmpty)
        }
    }

    @Test("no keepalives outside a frontend-tool dispatch")
    func plainTurn_noKeepalives() async throws {
        let session = makeSession(registry: ToolRegistry(), keepaliveInterval: 0.05)
        MockURLProtocol.responder = { _ in
            (200, sseBodyWithIds([
                #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r"}"#,
                #"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
                #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
                #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r"}"#,
            ]), Self.sseHeaders)
        }

        for try await _ in session.send("hi", context: { [] }) {}
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(MockURLProtocol.requestBodies.compactMap(Self.keepaliveState).isEmpty)
        #expect(MockURLProtocol.requestCount == 1)
    }

    @Test("backgrounding mid-dispatch sends one background notice and pauses pinging")
    func backgrounding_sendsNoticeAndPauses() async throws {
        let session = makeSession(
            registry: slowRegistry(sleepNanos: 350_000_000), keepaliveInterval: 0.05)
        Self.installResponder()

        let turn = Task { for try await _ in session.send("go", context: { [] }) {} }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await session.setHostBackgrounded(true)
        try? await turn.value

        let states = MockURLProtocol.requestBodies.compactMap(Self.keepaliveState)
        #expect(states.contains("background"), "background notice must be sent: \(states)")
        if let idx = states.firstIndex(of: "background") {
            let after = states[states.index(after: idx)...]
            #expect(after.filter { $0 == "active" }.count <= 1,
                    "pinging must pause while backgrounded: \(states)")
        }
        await session.setHostBackgrounded(false)
    }

    @Test("foregrounding mid-dispatch re-arms pinging with an active notice")
    func foregrounding_resumesPinging() async throws {
        let session = makeSession(
            registry: slowRegistry(sleepNanos: 350_000_000), keepaliveInterval: 0.05)
        Self.installResponder()

        let turn = Task { for try await _ in session.send("go", context: { [] }) {} }
        try? await Task.sleep(nanoseconds: 80_000_000)
        await session.setHostBackgrounded(true)
        try? await Task.sleep(nanoseconds: 80_000_000)
        await session.setHostBackgrounded(false)
        try? await turn.value

        let states = MockURLProtocol.requestBodies.compactMap(Self.keepaliveState)
        guard let bg = states.firstIndex(of: "background") else {
            Issue.record("no background notice in \(states)")
            return
        }
        let after = states[states.index(after: bg)...]
        #expect(after.contains("active"), "foreground must resume active pings: \(states)")
    }
}
}
