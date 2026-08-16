import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Resuming a turn killed while parked on a frontend tool (pupa#258).
///
/// The backend closes the SSE and parks while the client runs an on-device
/// tool. An app killed before it POSTs `command.resume` used to reattach past
/// the interrupt, find an empty tail, and report the turn settled — losing it.
/// Now the park's rewind cursor is persisted, so the relaunch re-fetches the
/// call list and answers it from the dispatch journal.
///
/// Disk-backed: `TestStorage.activate()` + `MyAppStore.clearStorage()` per the
/// shared-root serial rule.
@MainActor
@Suite("Parked dispatch recovery", .serialized)
struct ParkedDispatchRecoveryTests {

    init() { TestStorage.activate() }

    private func makeMemory() -> MemoryStore {
        MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pupa-tests-\(UUID().uuidString)"))
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelaunchMockURLProtocol.self]
        cfg.timeoutIntervalForRequest = 5
        return URLSession(configuration: cfg)
    }

    private func makeVM(store: MyAppStore, scope: ChatScope,
                        registry: ToolRegistry = ToolRegistry()) -> ChatViewModel {
        ChatViewModel(
            store: store, memory: makeMemory(),
            settings: SettingsStore(backendURL: URL(string: "http://mock.test/")!),
            registry: registry, scope: scope,
            threadId: store.currentThreadId(for: scope),
            urlSession: mockSession(), toolGateState: ToolGateState())
    }

    private func poll(timeout: Duration = .seconds(3), _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func sseFrames(_ events: [(seq: Int, json: String)]) -> Data {
        Data(events.map { "id: \($0.seq)\ndata: \($0.json)\n\n" }.joined().utf8)
    }

    /// `CUSTOM(on_interrupt)` asking for one call; the payload rides the wire
    /// as a JSON-encoded string.
    private func interruptFrame(id: String, name: String, args: String) -> String {
        let payload = #"{"frontend_tool_calls":[{"id":"\#(id)","name":"\#(name)","args":\#(args)}]}"#
        let escaped = payload
            .replacingOccurrences(of: "\\", with: #"\\"#)
            .replacingOccurrences(of: "\"", with: #"\""#)
        return #"{"type":"CUSTOM","name":"on_interrupt","value":"\#(escaped)"}"#
    }

    private func makeApp() -> (MyAppStore, ChatScope, String) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let scope: ChatScope = .myApp(a.id)
        return (store, scope, store.currentThreadId(for: scope))
    }

    private func writeJournal(_ records: [String: FrontendCallRecord], threadId: String) throws {
        let dir = FrontendDispatchJournalStore.dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: FrontendDispatchJournalStore.url(threadId), options: .atomic)
    }

    // MARK: - Rewind

    @Test("A snapshot parked on a frontend tool reattaches from the interrupt frame, not the cache end")
    func parkedSnapshot_reattachesFromRewindPoint() async throws {
        await MyAppStore.clearStorage()
        RelaunchMockURLProtocol.reset()
        let (store, scope, tid) = makeApp()

        // The kill landed after the interrupt was applied (cursor 6) while the
        // dispatch was still running. Rewinding to 5 re-delivers frame 6.
        TranscriptCache.save(
            TranscriptSnapshot(bubbles: [ChatBubble(role: .user, text: "add apple")],
                               lastEventSeq: 6, turnInFlight: true, savedAt: Date(),
                               pendingDispatchAfterSeq: 5),
            threadId: tid)
        RelaunchMockURLProtocol.sseBody = nil   // 204: park already gone

        let vm = makeVM(store: store, scope: scope)
        vm.loadHistoryIfNeeded()

        #expect(await poll { !RelaunchMockURLProtocol.postBodies.isEmpty })
        let post = try #require(RelaunchMockURLProtocol.postBodies.first)
        let input = try JSONDecoder().decode(RunAgentInput.self, from: post)
        #expect(input.forwardedProps["command"]?["reattach"]?["after_seq"]?.intValue == 5,
                "must rewind to the interrupt frame, not resume from the cache end (6)")
    }

    @Test("A journaled result answers the re-delivered call without re-running the tool")
    func parkedTurn_resumesFromJournal() async throws {
        await MyAppStore.clearStorage()
        RelaunchMockURLProtocol.reset()
        let (store, scope, tid) = makeApp()

        let ran = Counter()
        let registry = ToolRegistry()
        registry.register(ClientTool(
            descriptor: ToolDescriptor(name: "addItem", description: "add", parameters: ["type": "object"]),
            handler: { _ in
                await ran.bump()
                return .object(["ok": .bool(true), "ranNow": .bool(true)])
            }
        ))

        // Killed after the handler returned but before the resume went out.
        try writeJournal([
            "call_A": FrontendCallRecord(name: "addItem", result: .object([
                "ok": .bool(true), "fromJournal": .bool(true),
            ])),
        ], threadId: tid)
        TranscriptCache.save(
            TranscriptSnapshot(bubbles: [ChatBubble(role: .user, text: "add apple")],
                               lastEventSeq: 6, turnInFlight: true, savedAt: Date(),
                               pendingDispatchAfterSeq: 5),
            threadId: tid)

        RelaunchMockURLProtocol.sseBodies = [
            // Replayed tail: the interrupt the app never answered.
            sseFrames([
                (6, interruptFrame(id: "call_A", name: "addItem", args: #"{"item":"apple"}"#)),
                (7, #"{"type":"RUN_FINISHED","threadId":"\#(tid)","runId":"r1"}"#),
            ]),
            // The resume un-parks the run and the turn finishes.
            sseFrames([
                (8, #"{"type":"TEXT_MESSAGE_START","messageId":"m9","role":"assistant"}"#),
                (9, #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m9","delta":"Added apple."}"#),
                (10, #"{"type":"TEXT_MESSAGE_END","messageId":"m9"}"#),
                (11, #"{"type":"RUN_FINISHED","threadId":"\#(tid)","runId":"r2"}"#),
            ]),
        ]

        let vm = makeVM(store: store, scope: scope, registry: registry)
        vm.loadHistoryIfNeeded()

        #expect(await poll { RelaunchMockURLProtocol.postBodies.count >= 2 },
                "the re-delivered interrupt must produce a resume POST")
        let resume = try JSONDecoder().decode(
            RunAgentInput.self, from: RelaunchMockURLProtocol.postBodies[1])
        let results = try #require(
            resume.forwardedProps["command"]?["resume"]?["tool_results"]?.arrayValue)
        #expect(results.count == 1)
        #expect(results[0]["toolCallId"]?.stringValue == "call_A")
        let content = try #require(results[0]["content"]?.stringValue)
        #expect(content.contains("fromJournal"), "must ship the recorded result")
        #expect(!content.contains("ranNow"), "must not re-run the tool")
        #expect(await ran.value == 0, "a side-effecting tool must not fire twice")

        // The turn continues instead of being lost.
        #expect(await poll { vm.bubbles.contains { $0.text.contains("Added apple.") } })
        #expect(await poll { !vm.isStreaming })
        // Delivered → the record is spent.
        #expect(await poll {
            !FileManager.default.fileExists(atPath: FrontendDispatchJournalStore.url(tid).path)
        }, "journal is cleared once the resume lands")
        #expect(vm.pendingDispatchAfterSeq == nil)
    }

    @Test("An expired park says so instead of silently restarting the turn")
    func expiredPark_surfacesNotice() async throws {
        await MyAppStore.clearStorage()
        RelaunchMockURLProtocol.reset()
        let (store, scope, tid) = makeApp()

        try writeJournal(["call_A": FrontendCallRecord(name: "addItem")], threadId: tid)
        TranscriptCache.save(
            TranscriptSnapshot(bubbles: [ChatBubble(role: .user, text: "add apple")],
                               lastEventSeq: 6, turnInFlight: true, savedAt: Date(),
                               pendingDispatchAfterSeq: 5),
            threadId: tid)
        // Past the wall: the backend has nothing buffered and nothing parked.
        RelaunchMockURLProtocol.sseBody = nil

        let vm = makeVM(store: store, scope: scope)
        vm.loadHistoryIfNeeded()

        #expect(await poll {
            vm.bubbles.contains { $0.role == .system && $0.text.contains("timed out") }
        }, "the abandoned turn must be visible, not silent")
        #expect(await poll { vm.pendingDispatchAfterSeq == nil })
        #expect(await poll {
            !FileManager.default.fileExists(atPath: FrontendDispatchJournalStore.url(tid).path)
        }, "an undeliverable record is reaped")
    }

    @Test("A clean catch-up with nothing parked adds no notice")
    func nothingParked_noNotice() async throws {
        await MyAppStore.clearStorage()
        RelaunchMockURLProtocol.reset()
        let (store, scope, tid) = makeApp()

        TranscriptCache.save(
            TranscriptSnapshot(bubbles: [ChatBubble(role: .user, text: "hi")],
                               lastEventSeq: 6, turnInFlight: true, savedAt: Date(),
                               pendingDispatchAfterSeq: nil),
            threadId: tid)
        RelaunchMockURLProtocol.sseBody = nil

        let vm = makeVM(store: store, scope: scope)
        vm.loadHistoryIfNeeded()

        #expect(await poll { !vm.isStreaming })
        #expect(!vm.bubbles.contains { $0.role == .system },
                "pupa#103's clean no-op catch-up must stay silent")
    }

    // MARK: - Journal store lifetime

    @Test("The journal round-trips through disk and clears")
    func journalStore_roundTrips() async throws {
        await MyAppStore.clearStorage()
        let tid = "thread-\(UUID().uuidString)"
        let store = FrontendDispatchJournalStore(threadId: tid)

        await store.noteStarted(callId: "call_A", name: "addItem")
        #expect(await store.restore()["call_A"]?.isFinished == false)
        await store.noteFinished(callId: "call_A", result: .object(["ok": .bool(true)]))

        // A fresh instance reads what the previous process wrote.
        let reopened = FrontendDispatchJournalStore(threadId: tid)
        let record = try #require(await reopened.restore()["call_A"])
        #expect(record.name == "addItem")
        #expect(record.result?["ok"]?.boolValue == true)

        await reopened.clear()
        #expect(await FrontendDispatchJournalStore(threadId: tid).restore().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: FrontendDispatchJournalStore.url(tid).path))
    }

    @Test("Journals live outside the iCloud-mirrored subtrees")
    func journalStore_isDeviceLocal() async {
        let path = FrontendDispatchJournalStore.dir.path
        for mirrored in PupaStorage.mirroredSubtrees {
            #expect(!path.contains("/\(mirrored)/") && !path.hasSuffix("/\(mirrored)"),
                    "a record of what THIS device did must not sync to another device")
        }
    }

    @Test("The launch sweep reaps stale records and spares fresh ones")
    func journalStore_sweepsByAge() async throws {
        await MyAppStore.clearStorage()
        let stale = "thread-stale-\(UUID().uuidString)"
        let fresh = "thread-fresh-\(UUID().uuidString)"
        try writeJournal(["call_A": FrontendCallRecord(name: "addItem")], threadId: stale)
        try writeJournal(["call_B": FrontendCallRecord(name: "addItem")], threadId: fresh)
        // Back-date the stale one past the sweep window.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-48 * 60 * 60)],
            ofItemAtPath: FrontendDispatchJournalStore.url(stale).path)

        FrontendDispatchJournalStore.sweep()

        #expect(!FileManager.default.fileExists(atPath: FrontendDispatchJournalStore.url(stale).path))
        #expect(FileManager.default.fileExists(atPath: FrontendDispatchJournalStore.url(fresh).path))
    }

    @Test("Deleting a thread deletes its journal")
    func journalStore_deletedWithThread() async throws {
        await MyAppStore.clearStorage()
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let scope: ChatScope = .myApp(a.id)
        let tid = store.currentThreadId(for: scope)
        try writeJournal(["call_A": FrontendCallRecord(name: "addItem")], threadId: tid)

        store.removeThread(tid, for: scope)

        #expect(!FileManager.default.fileExists(atPath: FrontendDispatchJournalStore.url(tid).path))
    }

    // MARK: - Snapshot compatibility

    /// `Envelope` decoding is all-or-nothing, so a required new key would fail
    /// every pre-existing file AND the legacy bare-array fallback — silently
    /// wiping the device's whole cached history.
    @Test("A snapshot written before the parked-dispatch field still decodes")
    func oldSnapshot_stillDecodes() async throws {
        await MyAppStore.clearStorage()
        let tid = "thread-\(UUID().uuidString)"
        // Build a genuine v1 file: save one, then strip the new key and stamp
        // the old version, exactly as a pre-#258 install would have left it.
        TranscriptCache.save(
            TranscriptSnapshot(bubbles: [ChatBubble(role: .user, text: "hi")],
                               lastEventSeq: 6, turnInFlight: true, savedAt: Date(),
                               pendingDispatchAfterSeq: nil),
            threadId: tid)
        let url = TranscriptCache.url(tid)
        var json = try #require(String(data: try Data(contentsOf: url), encoding: .utf8))
        #expect(!json.contains("pendingDispatchAfterSeq"),
                "a nil Optional must not be written at all")
        json = json.replacingOccurrences(of: "\"v\":2", with: "\"v\":1")
        try Data(json.utf8).write(to: url, options: .atomic)

        let snapshot = try #require(TranscriptCache.loadSnapshot(tid),
                                    "a v1 file must still load, not wipe the transcript")
        #expect(snapshot.bubbles.count == 1)
        #expect(snapshot.lastEventSeq == 6)
        #expect(snapshot.turnInFlight)
        #expect(snapshot.pendingDispatchAfterSeq == nil)
    }
}

/// Counts handler invocations across actor hops.
private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
