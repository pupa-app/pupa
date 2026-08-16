import Foundation
import Testing
@testable import AGUIKit

/// Tests for the frontend-dispatch journal (pupa#258).
///
/// The backend parks with its SSE closed while the client runs a frontend tool.
/// An app killed before it POSTs `command.resume` loses the turn, and on
/// relaunch cannot tell a call that never ran from one that ran and only failed
/// to report. The journal records each call as it starts and finishes so the
/// relaunched app replays real results instead of re-applying side effects.
///
/// Nested inside `AgentSessionTests` for the same reason as `Reattach`: these
/// mutate `MockURLProtocol`'s non-isolated static state.
extension AgentSessionTests {
@Suite("Frontend dispatch journal", .serialized)
struct DispatchJournal {

    private static let sseHeaders: [String: String] = ["Content-Type": "text/event-stream"]

    private func makeClient() -> AgentClient {
        AgentClient(endpoint: URL(string: "http://mock.test/agent")!, session: makeMockSession())
    }

    private func freshSession(
        registry: ToolRegistry,
        journal: FrontendDispatchJournal?
    ) -> AgentSession {
        MockURLProtocol.reset()
        return AgentSession(
            client: makeClient(),
            registry: registry,
            threadId: "test-thread",
            journal: journal
        )
    }

    /// A `CUSTOM(on_interrupt)` frame asking for `calls`. The payload rides the
    /// wire as a JSON-encoded *string*, so it is escaped into `value`.
    private static func interruptFrame(_ calls: [(id: String, name: String, args: String)]) -> String {
        let items = calls
            .map { #"{"id":"\#($0.id)","name":"\#($0.name)","args":\#($0.args)}"# }
            .joined(separator: ",")
        let payload = #"{"frontend_tool_calls":[\#(items)]}"#
        let escaped = payload
            .replacingOccurrences(of: "\\", with: #"\\"#)
            .replacingOccurrences(of: "\"", with: #"\""#)
        return #"{"type":"CUSTOM","name":"on_interrupt","value":"\#(escaped)"}"#
    }

    /// Reattach tail that parks on `calls`, then a final answer on the resume.
    private static func scriptParkThenAnswer(_ calls: [(id: String, name: String, args: String)]) {
        JournalBodies.shared.tail = sseBodyWithIds([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            interruptFrame(calls),
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ], startSeq: 5)
        JournalBodies.shared.resume = sseBodyWithIds([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r3"}"#,
            #"{"type":"TEXT_MESSAGE_START","messageId":"mf","role":"assistant"}"#,
            #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"mf","delta":"done"}"#,
            #"{"type":"TEXT_MESSAGE_END","messageId":"mf"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r3"}"#,
        ], startSeq: 8)
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? JournalBodies.shared.tail!
                : JournalBodies.shared.resume!
            return (200, body, Self.sseHeaders)
        }
    }

    private func drain(_ stream: AsyncThrowingStream<SessionEvent, Error>) async {
        do { for try await _ in stream {} } catch {}
    }

    /// The `tool_results` array off the resume POST (request index `idx`).
    private func toolResults(requestIndex idx: Int) throws -> [AnyJSON] {
        let body = MockURLProtocol.requestBodies[idx]
        let input = try JSONDecoder().decode(RunAgentInput.self, from: body)
        return try #require(input.forwardedProps["command"]?["resume"]?["tool_results"]?.arrayValue)
    }

    /// Decode one `tool_results` entry's `content` (a JSON string) back to JSON.
    private func content(_ entry: AnyJSON) throws -> AnyJSON {
        let raw = try #require(entry["content"]?.stringValue)
        return try JSONDecoder().decode(AnyJSON.self, from: Data(raw.utf8))
    }

    private func recordingRegistry(_ recorder: CallRecorder, parallelSafe: Bool = false) -> ToolRegistry {
        let registry = ToolRegistry()
        for name in ["addItem", "readItems"] {
            registry.register(ClientTool(
                descriptor: ToolDescriptor(name: name, description: "t", parameters: ["type": "object"]),
                parallelSafe: parallelSafe,
                handler: { _ in
                    await recorder.record(name)
                    return .object(["ok": .bool(true), "ranNow": .bool(true)])
                }
            ))
        }
        return registry
    }

    // MARK: - Restored batches

    @Test("A journaled result is replayed verbatim — the handler never runs again")
    func restored_finishedCall_replaysStoredResult() async throws {
        let recorder = CallRecorder()
        let journal = TestJournal([
            "call_A": FrontendCallRecord(name: "addItem", result: .object([
                "ok": .bool(true), "fromJournal": .bool(true),
            ])),
        ])
        let session = freshSession(registry: recordingRegistry(recorder), journal: journal)
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        await session.seedReplayCursor(4)

        await drain(session.reattach())

        // The side effect may already have landed in the previous process —
        // re-running it would apply it twice.
        #expect(await recorder.count == 0)
        let results = try toolResults(requestIndex: 1)
        #expect(results.count == 1)
        #expect(try content(results[0])["fromJournal"]?.boolValue == true)
    }

    @Test("A call journaled started-but-unfinished is reported incomplete, not re-run")
    func restored_startedCall_reportsIncomplete() async throws {
        let recorder = CallRecorder()
        let journal = TestJournal(["call_A": FrontendCallRecord(name: "addItem")])
        let session = freshSession(registry: recordingRegistry(recorder), journal: journal)
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        await session.seedReplayCursor(4)

        await drain(session.reattach())

        #expect(await recorder.count == 0)
        let body = try content(try toolResults(requestIndex: 1)[0])
        #expect(body["ok"]?.boolValue == false)
        let error = try #require(body["error"]?.stringValue)
        #expect(error.contains("did not complete"))
    }

    @Test("A call with no journal entry runs normally on the restored batch")
    func restored_unknownCall_runsNormally() async throws {
        let recorder = CallRecorder()
        let session = freshSession(registry: recordingRegistry(recorder), journal: TestJournal())
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        await session.seedReplayCursor(4)

        await drain(session.reattach())

        #expect(await recorder.count == 1)
        #expect(try content(try toolResults(requestIndex: 1)[0])["ranNow"]?.boolValue == true)
    }

    // MARK: - Batch integrity

    /// The backend synthesises `missing_tool_result` for any batch call absent
    /// from the resume, so a partial answer corrupts the *other* calls. A batch
    /// with mixed journal states must still produce ONE resume carrying every
    /// result, in submission order.
    @Test("A mixed-state batch answers every call in one resume, in order")
    func mixedBatch_oneResumeEveryResultInOrder() async throws {
        let recorder = CallRecorder()
        let journal = TestJournal([
            "call_A": FrontendCallRecord(name: "addItem", result: .object(["tag": .string("stored")])),
            "call_B": FrontendCallRecord(name: "addItem"),   // started, never finished
        ])
        let session = freshSession(registry: recordingRegistry(recorder), journal: journal)
        Self.scriptParkThenAnswer([
            (id: "call_A", name: "addItem", args: #"{"item":"a"}"#),
            (id: "call_B", name: "addItem", args: #"{"item":"b"}"#),
            (id: "call_C", name: "addItem", args: #"{"item":"c"}"#),   // no entry → runs
        ])
        await session.seedReplayCursor(4)

        await drain(session.reattach())

        // Only the un-journaled call executed.
        #expect(await recorder.count == 1)
        // Exactly one resume POST (reattach tail + resume = 2 requests total).
        #expect(MockURLProtocol.requestCount == 2)
        let results = try toolResults(requestIndex: 1)
        #expect(results.map { $0["toolCallId"]?.stringValue } == ["call_A", "call_B", "call_C"])
        #expect(try content(results[0])["tag"]?.stringValue == "stored")
        #expect(try content(results[1])["ok"]?.boolValue == false)
        #expect(try content(results[2])["ranNow"]?.boolValue == true)
    }

    /// A journaled `parallelSafe` call must not even have a `Task` spawned —
    /// the side effect would fire before the sequential loop consults the map.
    @Test("A journaled parallel-safe call is never launched")
    func journaledParallelSafeCall_isNotLaunched() async throws {
        let recorder = CallRecorder()
        let journal = TestJournal([
            "call_A": FrontendCallRecord(name: "addItem", result: .object(["tag": .string("stored")])),
        ])
        let session = freshSession(
            registry: recordingRegistry(recorder, parallelSafe: true),
            journal: journal
        )
        Self.scriptParkThenAnswer([
            (id: "call_A", name: "addItem", args: #"{"item":"a"}"#),
            (id: "call_B", name: "addItem", args: #"{"item":"b"}"#),
        ])
        await session.seedReplayCursor(4)

        await drain(session.reattach())

        #expect(await recorder.count == 1)              // only call_B
        #expect(await recorder.names == ["addItem"])
        let results = try toolResults(requestIndex: 1)
        #expect(try content(results[0])["tag"]?.stringValue == "stored")
        #expect(try content(results[1])["ranNow"]?.boolValue == true)
    }

    /// The backend's own `claim_call` matches parked calls on `(name, args)`,
    /// which is exactly why the client side must stay id-exact: a batch may
    /// legitimately carry the same call twice.
    @Test("Two identical calls with distinct ids are answered per id, not merged")
    func duplicateCalls_answeredPerId() async throws {
        let recorder = CallRecorder()
        let journal = TestJournal([
            "call_A": FrontendCallRecord(name: "addItem", result: .object(["tag": .string("stored")])),
        ])
        let session = freshSession(registry: recordingRegistry(recorder), journal: journal)
        let args = #"{"item":"apple"}"#
        Self.scriptParkThenAnswer([
            (id: "call_A", name: "addItem", args: args),
            (id: "call_B", name: "addItem", args: args),   // same name+args, new id
        ])
        await session.seedReplayCursor(4)

        await drain(session.reattach())

        #expect(await recorder.count == 1)
        let results = try toolResults(requestIndex: 1)
        #expect(results.map { $0["toolCallId"]?.stringValue } == ["call_A", "call_B"])
        #expect(try content(results[0])["tag"]?.stringValue == "stored")
        #expect(try content(results[1])["ranNow"]?.boolValue == true)
    }

    // MARK: - Live dispatch bookkeeping

    @Test("A live dispatch records started then finished for every call")
    func liveDispatch_recordsStartedThenFinished() async throws {
        let recorder = CallRecorder()
        let journal = TestJournal()
        let session = freshSession(registry: recordingRegistry(recorder), journal: journal)
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        await session.seedReplayCursor(4)

        await drain(session.reattach())

        #expect(await recorder.count == 1)
        #expect(await journal.startedOrder == ["call_A"])
        #expect(await journal.finishedOrder == ["call_A"])
    }

    @Test("The journal is cleared only once the resume has reached the backend")
    func journalCleared_afterResumeLands() async throws {
        let recorder = CallRecorder()
        let journal = TestJournal()
        let session = freshSession(registry: recordingRegistry(recorder), journal: journal)
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        await session.seedReplayCursor(4)

        await drain(session.reattach())

        // Cleared after the resume round returned, and nothing is left behind.
        #expect(await journal.clearCount >= 1)
        #expect(await journal.records.isEmpty)
        // The clear must land AFTER the resume POST — otherwise a kill mid-POST
        // would lose the results and re-run the tools on the next wake.
        #expect(await journal.clearsBeforeFirstRestore == 0)
    }

    // MARK: - Rewind point

    @Test("Parking on an interrupt yields the cursor that re-delivers that frame")
    func parkedEvent_carriesRewindPoint() async throws {
        let recorder = CallRecorder()
        let session = freshSession(registry: recordingRegistry(recorder), journal: TestJournal())
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        await session.seedReplayCursor(4)

        var parked: [Int] = []
        var resolved = 0
        for try await ev in session.reattach() {
            switch ev {
            case .frontendDispatchParked(let afterSeq): parked.append(afterSeq)
            case .frontendDispatchResolved: resolved += 1
            default: break
            }
        }

        // Tail starts at 5 (RUN_STARTED); the interrupt is the next frame, 6.
        // Rewinding to 5 re-delivers it, since the backend replays seq > after_seq.
        #expect(parked == [5])
        #expect(resolved == 1)
    }

    @Test("An unstamped interrupt frame yields no rewind point")
    func unstampedInterrupt_yieldsNoRewindPoint() async throws {
        let recorder = CallRecorder()
        let session = freshSession(registry: recordingRegistry(recorder), journal: TestJournal())
        // No `id:` lines — a backend predating the replay layer.
        JournalBodies.shared.tail = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r2"}"#,
            Self.interruptFrame([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)]),
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r2"}"#,
        ])
        JournalBodies.shared.resume = sseBody([
            #"{"type":"RUN_STARTED","threadId":"test-thread","runId":"r3"}"#,
            #"{"type":"RUN_FINISHED","threadId":"test-thread","runId":"r3"}"#,
        ])
        MockURLProtocol.responder = { _ in
            let body = MockURLProtocol.requestCount == 1
                ? JournalBodies.shared.tail!
                : JournalBodies.shared.resume!
            return (200, body, Self.sseHeaders)
        }
        await session.seedReplayCursor(4)

        var parked: [Int] = []
        for try await ev in session.reattach() {
            if case .frontendDispatchParked(let afterSeq) = ev { parked.append(afterSeq) }
        }

        #expect(parked.isEmpty)
        #expect(await recorder.count == 1)   // still dispatched, just not recoverable
    }

    // MARK: - Dropped resume

    /// The replay log can only serve what the backend already emitted, and a
    /// parked backend emits nothing until it gets the results. So a dropped
    /// resume POST must re-send the RESULTS; a bare re-attach would come back
    /// empty, read as a clean finish, and strand the park forever — losing the
    /// turn this whole feature exists to save.
    @Test("A dropped resume POST re-sends the results, not a bare re-attach")
    func droppedResumePost_resendsResults() async throws {
        let recorder = CallRecorder()
        let journal = TestJournal()
        let session = freshSession(registry: recordingRegistry(recorder), journal: journal)
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        // POST #2 is the resume — kill it at connect time.
        MockURLProtocol.failer = { idx in idx == 2 ? URLError(.networkConnectionLost) : nil }
        await session.seedReplayCursor(4)

        var resolved = 0
        for try await ev in session.reattach() {
            if case .frontendDispatchResolved = ev { resolved += 1 }
        }

        // #1 tail, #2 dropped resume, #3 the retry.
        #expect(MockURLProtocol.requestCount == 3)
        let retry = try JSONDecoder().decode(
            RunAgentInput.self, from: MockURLProtocol.requestBodies[2])
        let results = retry.forwardedProps["command"]?["resume"]?["tool_results"]?.arrayValue
        #expect(results?.first?["toolCallId"]?.stringValue == "call_A",
                "the retry must carry the tool results, not command.reattach")
        #expect(retry.forwardedProps["command"]?["reattach"] == nil)
        #expect(resolved == 1)
        #expect(await recorder.count == 1, "the tool must not run twice on the retry")
    }

    // The mirror case — a resume that drops AFTER a frame has arrived must
    // re-attach rather than re-send, since the backend demonstrably got the
    // results — is enforced by the `sawAnyFrame` guard in `reattachAfterDrop`
    // but is not covered here: `MockURLProtocol` emits `didLoad` and
    // `didFailWithError` back to back, so `URLSession.bytes` throws before the
    // buffered frame reaches the decoder and the case can't be staged.

    @Test("A resume that never lands keeps the journal for the next wake")
    func undeliverableResume_keepsJournal() async throws {
        let recorder = CallRecorder()
        let journal = TestJournal()
        let session = freshSession(registry: recordingRegistry(recorder), journal: journal)
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        // Every resume attempt dies — the backend never gets the results.
        MockURLProtocol.failer = { idx in idx >= 2 ? URLError(.networkConnectionLost) : nil }
        await session.seedReplayCursor(4)

        var resolved = 0
        do {
            for try await ev in session.reattach() {
                if case .frontendDispatchResolved = ev { resolved += 1 }
            }
        } catch {
            // Surfaced to the host as a connection failure — expected.
        }

        #expect(resolved == 0, "nothing was delivered, so nothing is resolved")
        #expect(await journal.records["call_A"]?.isFinished == true,
                "the recorded result must survive for the next attempt")
    }

    // MARK: - Tool surface

    /// The resume's `tools_after_round` tells the backend what to expose next.
    /// The claude harness diffs it against the live session's surface and treats
    /// a wider list as a gate unlock — rebuilding its client (breaking the
    /// prompt cache) and injecting a synthetic "the tools you activated are now
    /// available" turn for a gate nobody touched. A recovery must therefore
    /// advertise exactly what a live send would.
    @Test("A recovery advertises the gated tool surface, never the whole registry")
    func recoveryHonoursToolFilter() async throws {
        let recorder = CallRecorder()
        let session = freshSession(registry: recordingRegistry(recorder), journal: TestJournal())
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        await session.seedReplayCursor(4)

        // The gate exposes only `addItem`; `readItems` is registered but hidden.
        await drain(session.reattach(toolFilter: { ["addItem"] }))

        let resume = try JSONDecoder().decode(
            RunAgentInput.self, from: MockURLProtocol.requestBodies[1])
        let advertised = try #require(
            resume.forwardedProps["command"]?["resume"]?["tools_after_round"]?.arrayValue)
        #expect(advertised.compactMap { $0["name"]?.stringValue } == ["addItem"])
        #expect(resume.tools.map(\.name) == ["addItem"])
    }

    @Test("With no filter a recovery still advertises the full registry")
    func recoveryWithoutFilter_advertisesEverything() async throws {
        let recorder = CallRecorder()
        let session = freshSession(registry: recordingRegistry(recorder), journal: TestJournal())
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        await session.seedReplayCursor(4)

        await drain(session.reattach())

        let resume = try JSONDecoder().decode(
            RunAgentInput.self, from: MockURLProtocol.requestBodies[1])
        let advertised = try #require(
            resume.forwardedProps["command"]?["resume"]?["tools_after_round"]?.arrayValue)
        #expect(Set(advertised.compactMap { $0["name"]?.stringValue }) == ["addItem", "readItems"])
    }

    // MARK: - Regressions

    @Test("With no journal the dispatch behaves exactly as before")
    func noJournal_dispatchesNormally() async throws {
        let recorder = CallRecorder()
        let session = freshSession(registry: recordingRegistry(recorder), journal: nil)
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        await session.seedReplayCursor(4)

        await drain(session.reattach())

        #expect(await recorder.count == 1)
        #expect(MockURLProtocol.requestCount == 2)
        #expect(try toolResults(requestIndex: 1).count == 1)
    }

    @Test("An interrupt in the replayed tail dispatches exactly once — no double dispatch")
    func replayedInterrupt_dispatchesOnce() async throws {
        let recorder = CallRecorder()
        let session = freshSession(registry: recordingRegistry(recorder), journal: TestJournal())
        Self.scriptParkThenAnswer([(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)])
        await session.seedReplayCursor(4)

        var finishedIds: [String] = []
        for try await ev in session.reattach() {
            if case .toolCallFinished(let id, _, _, _) = ev { finishedIds.append(id) }
        }

        #expect(await recorder.count == 1)
        #expect(finishedIds == ["call_A"])
    }
}
}

// MARK: - Test doubles

/// In-memory `FrontendDispatchJournal`, standing in for the app's on-disk store.
private actor TestJournal: FrontendDispatchJournal {
    private(set) var records: [String: FrontendCallRecord]
    private(set) var startedOrder: [String] = []
    private(set) var finishedOrder: [String] = []
    private(set) var clearCount = 0
    /// Clears that happened before the session ever read the journal — a
    /// non-zero value means the record was dropped before its results shipped.
    private(set) var clearsBeforeFirstRestore = 0
    private var didRestore = false

    init(_ seed: [String: FrontendCallRecord] = [:]) { records = seed }

    func noteStarted(callId: String, name: String) {
        records[callId] = FrontendCallRecord(name: name)
        startedOrder.append(callId)
    }

    func noteFinished(callId: String, result: AnyJSON) {
        records[callId] = FrontendCallRecord(name: records[callId]?.name ?? "", result: result)
        finishedOrder.append(callId)
    }

    func restore() -> [String: FrontendCallRecord] {
        didRestore = true
        return records
    }

    func clear() {
        if !didRestore { clearsBeforeFirstRestore += 1 }
        records.removeAll()
        clearCount += 1
    }
}

/// Records which handlers actually executed.
private actor CallRecorder {
    private(set) var names: [String] = []
    var count: Int { names.count }
    func record(_ name: String) { names.append(name) }
}

/// Round-specific SSE bodies (same pattern as `Bodies` in `ReattachTests`).
private final class JournalBodies: @unchecked Sendable {
    static let shared = JournalBodies()
    var tail: Data?
    var resume: Data?
}
