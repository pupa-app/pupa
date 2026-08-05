import Foundation
import Testing
@testable import AGUIKit
@testable import PupaApp

/// Regression test for the "agent stopped silently" bug.
///
/// Repro from the field: the agent emits a `shell` command, the backend's
/// `ShellApprovalMiddleware` pauses on a `request_shell_approval` interrupt,
/// and the iOS client shows the Approve/Deny card. While the card is up the
/// turn is still in flight, so `isStreaming` stays true — which made the
/// composer's primary button a *Stop* button. Tapping it (or any other path
/// into `cancel()`) tore down the session task, so the resume POST never
/// fired: the backend interrupt was left parked forever and the next message
/// landed as a fresh run that silently dropped the approved command.
///
/// The fix: `cancel()` while parked on a human-in-the-loop interrupt must
/// resolve it (deny) and let the *live* AGUIKit loop POST the resume, instead
/// of cancelling the task. This test drives the real `ChatViewModel` loop
/// against a mock backend and asserts the deny-resume actually reaches the
/// wire (a second POST), rather than orphaning the interrupt.
@MainActor
@Suite("Shell approval interrupt — cancel must not orphan", .serialized)
struct ShellApprovalInterruptTests {

    private func makeMemory() -> MemoryStore {
        MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pupa-tests-\(UUID().uuidString)"))
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [InterruptMockURLProtocol.self]
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }

    /// Spin the run loop (which lives on a detached task) until `cond` holds
    /// or the deadline passes. Runs on the MainActor, so `Task.sleep` yields
    /// and lets the streaming task make progress between checks.
    private func poll(
        timeout: Duration = .seconds(3),
        _ cond: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if cond() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("cancel() while parked on a shell-approval interrupt POSTs a deny-resume instead of orphaning the backend interrupt")
    func cancelDuringShellApproval_postsDenyResume_doesNotOrphan() async throws {
        InterruptMockURLProtocol.reset()
        MyAppTypeRegistry.shared.registerBuiltins()

        // The exact heredoc shape from the bug report — a *multiline* command,
        // which also exercises the on_interrupt decode path end to end (the
        // card must render the full command, proving decode handles newlines).
        let command = """
        cd ~/.pupa-backend && cat >> config.yml <<'EOF'
          elevenlabs:
            enabled: true
            command: uvx
            args:
            - elevenlabs-mcp
        EOF
        echo "appended."
        """

        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let scope: ChatScope = .myApp(a.id)
        let registry = ToolRegistry()
        let vm = ChatViewModel(
            store: store,
            memory: makeMemory(),
            settings: SettingsStore(backendURL: URL(string: "http://mock.test/agent")!),
            registry: registry,
            scope: scope,
            threadId: store.currentThreadId(for: scope),
            urlSession: mockSession(),
            toolGateState: ToolGateState()
        )

        // The real `request_shell_approval` frontend tool is backed by the
        // view model's `HumanInTheLoopBridge`. Register the same wiring the
        // app uses so a dispatched interrupt suspends on the Approve/Deny card.
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "request_shell_approval",
                description: "Approve or deny a shell command before it runs.",
                parameters: ["type": "object"]
            ),
            handler: { [weak vm] args in
                guard let vm else { return .object(["approved": .bool(false), "remember": .bool(false)]) }
                let cmd: String
                if case .string(let c)? = args["command"] { cmd = c } else { cmd = "" }
                let decision = await vm.requestShellApproval(command: cmd)
                return .object([
                    "approved": .bool(decision.approved),
                    "remember": .bool(decision.remember),
                ])
            }
        ))

        // Round 1 pauses on the shell-approval interrupt; round 2 is whatever
        // the model says after it sees the denial.
        let round1 = sseEvents([
            #"{"type":"RUN_STARTED","threadId":"t","runId":"r1"}"#,
            onInterruptEvent(callId: "call_sh", toolName: "request_shell_approval", args: ["command": command]),
            #"{"type":"RUN_FINISHED","threadId":"t","runId":"r1"}"#,
        ])
        let round2 = sseEvents([
            #"{"type":"RUN_STARTED","threadId":"t","runId":"r2"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"m2","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m2","delta":"Understood — I won't run it."}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"m2"}"#,
            #"{"type":"RUN_FINISHED","threadId":"t","runId":"r2"}"#,
        ])
        InterruptMockURLProtocol.responder = { count in
            (200, count == 1 ? round1 : round2, ["Content-Type": "text/event-stream"])
        }

        // Kick off the turn and wait for the approval card to appear.
        vm.send("set up the elevenlabs mcp")
        await poll { vm.hasPendingShellApproval }

        #expect(vm.hasPendingShellApproval, "the shell-approval card should be parked and awaiting a decision")
        #expect(vm.isAwaitingHumanInput, "an interrupt is pending → composer must suppress its Stop affordance")
        #expect(InterruptMockURLProtocol.requestCount == 1, "exactly the initial send so far")
        // The multiline command round-tripped intact into the card (decode is
        // not the failure mode — the resume POST is).
        #expect(
            vm.bubbles.contains { $0.role == .shellApproval && $0.text == command },
            "the full multiline command should render in the approval card"
        )

        // The bug trigger: the user hits the composer button — which is a
        // Stop button while the turn streams — instead of the card's Deny,
        // routing into cancel().
        let streamingWhileParked = vm.isStreaming
        vm.cancel()

        // Deterministic, synchronous discriminators of the fix — no network
        // race. `session.bytes(for:)` fires the POST before AGUIKit's
        // cancellation check, so over an instant mock the resume "arrives"
        // either way; in production the cancel aborts the socket mid-flight
        // and the backend never processes it. So we don't assert on the wire
        // here — we assert the *code contract* that prevents the teardown:
        //
        //  • Pre-fix `cancel()` ran `setStreaming(false)` and left no decision
        //    trail, tearing the turn down → orphaned interrupt.
        //  • The fix resolves the interrupt with a Deny and keeps the turn in
        //    flight so the live loop can carry the resume to completion.
        #expect(streamingWhileParked, "sanity: the turn is in flight while the card is up")
        #expect(
            vm.isStreaming,
            "cancel() during an interrupt must NOT tear the turn down — it has to stay in flight to deliver the resume (pre-fix this went false here, orphaning the interrupt)"
        )
        #expect(
            vm.bubbles.last.map { $0.role == .user && $0.text == "Deny" } == true,
            "cancel() during a shell approval records a Deny decision so it reaches the backend (pre-fix: no decision bubble)"
        )
        #expect(vm.hasPendingShellApproval == false, "the interrupt is resolved client-side")

        // With the turn kept alive, the run settles cleanly: the deny-resume
        // round runs to completion and the model's follow-up reply is applied.
        await poll { vm.isStreaming == false }
        #expect(vm.isStreaming == false, "the turn settles once the backend processes the denial")
        try #require(
            InterruptMockURLProtocol.requestCount == 2,
            "the deny-resume must be POSTed as a second round"
        )
        #expect(
            vm.bubbles.contains { $0.text.contains("won't run it") },
            "the model's post-denial reply should arrive and render"
        )

        // The resume body carried the deny decision for the right tool call.
        let resumeBody = InterruptMockURLProtocol.requestBodies[1]
        let root = try JSONSerialization.jsonObject(with: resumeBody) as? [String: Any]
        let resume = ((root?["forwardedProps"] as? [String: Any])?["command"] as? [String: Any])?["resume"] as? [String: Any]
        let results = resume?["tool_results"] as? [[String: Any]]
        let first = try #require(results?.first, "resume payload should carry one tool_result")
        #expect(first["toolCallId"] as? String == "call_sh")
        let content = try #require(first["content"] as? String)
        #expect(
            content.contains("\"approved\":false"),
            "the resume tool_result should encode the deny decision; got \(content)"
        )
    }
}

// MARK: - Test helpers

/// Encode JSON event strings as an SSE body (`data: …\n\n`).
private func sseEvents(_ events: [String]) -> Data {
    Data(events.map { "data: \($0)\n\n" }.joined().utf8)
}

/// Build a `CUSTOM(on_interrupt, value=…)` event the way the backend
/// does: the interrupt dict is JSON-encoded into a *string* `value`. Built
/// with `JSONSerialization` so the multiline command's newlines are escaped
/// correctly through both encoding layers.
private func onInterruptEvent(callId: String, toolName: String, args: [String: Any]) -> String {
    let inner: [String: Any] = [
        "frontend_tool_calls": [["id": callId, "name": toolName, "args": args]],
    ]
    let innerString = String(decoding: try! JSONSerialization.data(withJSONObject: inner), as: UTF8.self)
    let event: [String: Any] = ["type": "CUSTOM", "name": "on_interrupt", "value": innerString]
    return String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
}

/// URLProtocol stub with a per-request-count responder so a test can serve a
/// distinct body for the initial send vs the resume round, and assert how
/// many POSTs actually reached the wire. Named to avoid clashing with the
/// single-shot `MockURLProtocol` in `BackendPairingTests`.
final class InterruptMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: (@Sendable (Int) -> (Int, Data, [String: String]))?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var requestBodies: [Data] = []

    static func reset() {
        responder = nil
        requestCount = 0
        requestBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        InterruptMockURLProtocol.requestCount += 1
        let count = InterruptMockURLProtocol.requestCount

        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: 4096)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            InterruptMockURLProtocol.requestBodies.append(data)
        } else {
            InterruptMockURLProtocol.requestBodies.append(request.httpBody ?? Data())
        }

        guard let responder = InterruptMockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, body, headers) = responder(count)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://mock/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
