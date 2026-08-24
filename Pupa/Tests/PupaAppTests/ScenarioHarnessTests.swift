import Foundation
import Testing
import AGUIKit
import PupaHarness
@testable import PupaApp

/// The harness itself, pinned end to end: a scripted backend parks a turn on a
/// frontend tool, the real `ChatSessionCoordinator` graph runs the real handler,
/// and `ScenarioReport` shows what happened on all four surfaces — chat,
/// canvas, recovery records, wire.
///
/// If this suite passes, `PupaCtl replay` and the launched app's `-PupaScript`
/// mode are driving the same seam.
///
/// `.serialized`: `ScriptedTransport` statics and `PupaStorage.overrideRoot`
/// are process-global.
@MainActor
@Suite("Scenario harness", .serialized)
struct ScenarioHarnessTests {

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-scenario-\(UUID().uuidString)", isDirectory: true)
    }

    /// Round 1 asks for `addComponent` and parks; round 2 closes the turn.
    private static let addComponentScript = """
    {"events":[
      {"type":"RUN_STARTED","threadId":"t","runId":"r1"},
      {"type":"TOOL_CALL_START","toolCallId":"call_1","toolCallName":"addComponent"},
      {"type":"TOOL_CALL_ARGS","toolCallId":"call_1","delta":"{\\"kind\\":\\"tracker\\",\\"name\\":\\"Books\\"}"},
      {"type":"TOOL_CALL_END","toolCallId":"call_1"},
      {"type":"CUSTOM","name":"on_interrupt","value":"{\\"frontend_tool_calls\\":[{\\"id\\":\\"call_1\\",\\"name\\":\\"addComponent\\",\\"args\\":{\\"kind\\":\\"tracker\\",\\"name\\":\\"Books\\"}}]}"},
      {"type":"RUN_FINISHED","threadId":"t","runId":"r1"}
    ]}
    {"events":[
      {"type":"RUN_STARTED","threadId":"t","runId":"r2"},
      {"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"},
      {"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"Added Books."},
      {"type":"TEXT_MESSAGE_END","messageId":"m1"},
      {"type":"RUN_FINISHED","threadId":"t","runId":"r2"}
    ]}
    """

    @Test("a scripted turn runs the real tool and lands on the canvas")
    func scriptedTurn_executesFrontendTool() async throws {
        ScriptedTransport.reset()
        ScriptedTransport.script = try Script.parse(Self.addComponentScript)
        defer { ScriptedTransport.reset() }

        let scenario = Scenario(
            root: makeRoot(),
            backend: URL(string: "http://scripted.invalid/")!,
            urlSession: ScriptedTransport.session())
        defer { scenario.restoreStorageRoot() }

        let before = scenario.store.myApps.first { $0.id == scenario.myAppId }?.components.count ?? 0
        let settled = await scenario.send("add a Books tracker")
        #expect(settled, "turn never settled")

        let report = scenario.report()

        // The handler ran for real — this is the app's `addComponent`, not a stub.
        let after = report.myApp?.components.count ?? 0
        #expect(after == before + 1)
        #expect(report.myApp?.components.contains { $0.name == "Books" } == true)

        // …and every surface the report claims to cover shows it.
        #expect(report.toolCalls.map(\.name) == ["addComponent"])
        #expect(report.toolCalls.first?.state == .done)
        #expect(report.assistantText.contains("Added Books."))
        #expect(report.rounds.count == 2, "park + resume is two rounds")
    }

    /// The journal is what lets a killed app answer a parked turn without
    /// re-running side effects. Once the turn settles it must be gone, and the
    /// snapshot must no longer claim a turn is in flight.
    @Test("a settled turn leaves no parked-dispatch record behind")
    func settledTurn_clearsRecoveryRecords() async throws {
        ScriptedTransport.reset()
        ScriptedTransport.script = try Script.parse(Self.addComponentScript)
        defer { ScriptedTransport.reset() }

        let scenario = Scenario(
            root: makeRoot(),
            backend: URL(string: "http://scripted.invalid/")!,
            urlSession: ScriptedTransport.session())
        defer { scenario.restoreStorageRoot() }

        _ = await scenario.send("add a Books tracker")
        // The snapshot lands on a detached task after settle — poll, don't sample.
        let report = await scenario.waitForReport { $0.recovery?.turnInFlight == false }

        #expect(report.journal == nil, "journal outlived the turn")
        #expect(report.recovery?.turnInFlight == false)
    }

    /// Round-addressing: an explicit `round` wins over file order, so a
    /// fixture can pin one round and leave the rest positional.
    @Test("scripts address rounds explicitly or positionally")
    func script_roundAddressing() throws {
        ScriptedTransport.reset()
        defer { ScriptedTransport.reset() }
        ScriptedTransport.script = try Script.parse("""
        {"events":[{"type":"RUN_FINISHED","threadId":"t","runId":"positional"}]}
        {"round":2,"events":[{"type":"RUN_FINISHED","threadId":"t","runId":"pinned"}]}
        """)

        #expect(ScriptedTransport.round(for: 1)?.round == nil)
        #expect(ScriptedTransport.round(for: 2)?.round == 2)
        #expect(ScriptedTransport.round(for: 3) == nil, "past the end serves 204")
    }

    /// A script survives a round-trip through `.jsonl`, which is what makes
    /// `PupaCtl record` output replayable.
    @Test("a script round-trips through jsonl")
    func script_roundTrips() throws {
        let original = try Script.parse(Self.addComponentScript)
        let reparsed = try Script.parse(original.jsonl())
        #expect(reparsed.rounds.count == original.rounds.count)
        #expect(reparsed.rounds.first?.events.count == original.rounds.first?.events.count)
    }

    /// `record` is only useful if a live round's raw SSE comes back as a
    /// scriptable round — the `id:` lines the backend stamps included.
    @Test("recorded SSE decodes into a replayable round")
    func recording_decodesSSEIntoScript() throws {
        let sse = """
        id: 0
        data: {"type":"RUN_STARTED","threadId":"t","runId":"r1"}

        id: 1
        data: {"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"hi"}

        id: 2
        data: {"type":"RUN_FINISHED","threadId":"t","runId":"r1"}


        """
        let round = RecordingTransport.round(from: Data(sse.utf8), status: 200)
        #expect(round.events.count == 3)
        #expect(round.events.first?["type"]?.stringValue == "RUN_STARTED")
        #expect(round.status == nil, "200 is the default — don't write it out")

        // …and what it decoded is servable again.
        let replayed = try Script.parse(Script(rounds: [round]).jsonl())
        #expect(replayed.rounds.first?.events.count == 3)
    }
}
