import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Serves canned responses for the relaunch catch-up flow: SSE replay tails
/// for `POST /` (the reattach) and an empty transcript for `GET /db/...`.
/// Records every POST body so tests can assert the `after_seq` wire.
final class RelaunchMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// SSE body served to `POST /`; nil → 204 No Content.
    nonisolated(unsafe) static var sseBody: Data?
    /// Per-POST bodies, served by request index. Takes precedence over
    /// `sseBody` when set — a multi-round flow (park → resume) needs a
    /// different body per round. Past the end falls back to `sseBody`.
    nonisolated(unsafe) static var sseBodies: [Data]?
    nonisolated(unsafe) static var postBodies: [Data] = []
    /// Connect-time failure injector, keyed by 1-based POST index — mimics a
    /// dropped socket so the session's retry ladder can be driven.
    nonisolated(unsafe) static var failPostAt: (@Sendable (Int) -> URLError?)?

    static func reset() {
        sseBody = nil
        sseBodies = nil
        postBodies = []
        failPostAt = nil
    }

    /// Body for the POST being served (bodies are appended before this runs).
    static func bodyForCurrentPost() -> Data? {
        let idx = postBodies.count - 1
        if let scripted = sseBodies, idx >= 0, idx < scripted.count { return scripted[idx] }
        return sseBody
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isPost = request.httpMethod == "POST"
        if isPost {
            var data = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate(); stream.close() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: 4096)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
            } else {
                data = request.httpBody ?? Data()
            }
            Self.postBodies.append(data)

            if let failer = Self.failPostAt, let err = failer(Self.postBodies.count) {
                client?.urlProtocol(self, didFailWithError: err)
                return
            }

            guard let body = Self.bodyForCurrentPost() else {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 204,
                                           httpVersion: nil, headerFields: [:])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // GET transcript fetch → empty list (never clobbers the cache).
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Launch-time catch-up after an app kill (pupa#103): a thread whose cached
/// snapshot says a turn was in flight seeds the session's replay cursor and
/// reattaches on first open, continuing the transcript from where the cache
/// ends instead of showing "connection closed".
///
/// Disk-backed: `TestStorage.activate()` + `MyAppStore.clearStorage()` per the
/// shared-root serial rule.
@MainActor
@Suite("Relaunch catch-up", .serialized)
struct RelaunchCatchUpTests {

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
                        session: URLSession? = nil) -> ChatViewModel {
        ChatViewModel(
            store: store, memory: makeMemory(),
            settings: SettingsStore(backendURL: URL(string: "http://mock.test/")!),
            registry: ToolRegistry(), scope: scope,
            threadId: store.currentThreadId(for: scope),
            urlSession: session ?? mockSession(), toolGateState: ToolGateState())
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

    // MARK: - The core relaunch flow

    @Test("in-flight snapshot on first open seeds after_seq and replays the tail into the transcript")
    func relaunch_inFlightSnapshot_catchesUp() async {
        await MyAppStore.clearStorage()
        RelaunchMockURLProtocol.reset()
        MyAppTypeRegistry.shared.registerBuiltins()

        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let scope: ChatScope = .myApp(a.id)
        let tid = store.currentThreadId(for: scope)

        // The state a kill left behind: user question + half an answer, cursor
        // at the last applied frame, turn still in flight.
        let halfBubbles = [
            ChatBubble(role: .user, text: "long question"),
            ChatBubble(id: "m1", role: .assistant, text: "first half"),
        ]
        TranscriptCache.save(
            TranscriptSnapshot(bubbles: halfBubbles, lastEventSeq: 6,
                               turnInFlight: true, savedAt: Date()),
            threadId: tid)

        // Backend replays everything after seq 6, then the turn settles.
        RelaunchMockURLProtocol.sseBody = sseFrames([
            (7, #"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":" second half"}"#),
            (8, #"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#),
            (9, #"{"type":"RUN_FINISHED","threadId":"\#(tid)","runId":"r"}"#),
        ])

        let vm = makeVM(store: store, scope: scope)
        vm.loadHistoryIfNeeded()

        #expect(await poll { vm.bubbles.first(where: { $0.id == "m1" })?.text == "first half second half" },
                "replayed tail continues the cached half-message")
        #expect(await poll { !vm.isStreaming }, "turn settles after the replayed RUN_FINISHED")
        #expect(vm.connectionIssue == nil)
        #expect(!vm.bubbles.contains { $0.role == .system },
                "no 'connection closed' notice on a clean catch-up")

        // The reattach POST carried the persisted cursor.
        let post = RelaunchMockURLProtocol.postBodies.first
        #expect(post != nil, "catch-up must fire a reattach POST")
        if let post, let input = try? JSONDecoder().decode(RunAgentInput.self, from: post) {
            #expect(input.forwardedProps["command"]?["reattach"]?["after_seq"]?.intValue == 6)
        }

        // The settle persisted a fresh snapshot with the turn closed.
        #expect(await poll { TranscriptCache.loadSnapshot(tid)?.turnInFlight == false })
    }

    @Test("settled snapshot does not fire a reattach on open")
    func relaunch_settledSnapshot_noCatchUp() async {
        await MyAppStore.clearStorage()
        RelaunchMockURLProtocol.reset()
        MyAppTypeRegistry.shared.registerBuiltins()

        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let scope: ChatScope = .myApp(a.id)
        let tid = store.currentThreadId(for: scope)
        TranscriptCache.save(
            TranscriptSnapshot(bubbles: [ChatBubble(role: .user, text: "done")],
                               lastEventSeq: 12, turnInFlight: false, savedAt: Date()),
            threadId: tid)

        let vm = makeVM(store: store, scope: scope)
        vm.loadHistoryIfNeeded()

        try? await Task.sleep(for: .milliseconds(300))
        #expect(RelaunchMockURLProtocol.postBodies.isEmpty, "no turn in flight → no reattach POST")
        #expect(!vm.isStreaming)
    }

    @Test("expired replay buffer (204) settles the catch-up silently — no dropped-stream notice")
    func relaunch_bufferGone_settlesSilently() async {
        await MyAppStore.clearStorage()
        RelaunchMockURLProtocol.reset()  // sseBody nil → POST answered 204
        MyAppTypeRegistry.shared.registerBuiltins()

        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let scope: ChatScope = .myApp(a.id)
        let tid = store.currentThreadId(for: scope)
        TranscriptCache.save(
            TranscriptSnapshot(bubbles: [ChatBubble(role: .user, text: "old turn")],
                               lastEventSeq: 3, turnInFlight: true, savedAt: Date()),
            threadId: tid)

        let vm = makeVM(store: store, scope: scope)
        vm.loadHistoryIfNeeded()

        #expect(await poll { !RelaunchMockURLProtocol.postBodies.isEmpty }, "catch-up still attempts")
        #expect(await poll { !vm.isStreaming })
        #expect(vm.connectionIssue == nil)
        #expect(!vm.bubbles.contains { $0.role == .system },
                "204 is a benign no-op, not a connection failure")
        #expect(await poll { TranscriptCache.loadSnapshot(tid)?.turnInFlight == false },
                "the settled catch-up clears the in-flight flag")
    }

    // MARK: - Persist cadence

    @Test("send persists an in-flight snapshot so an immediate kill can catch up")
    func send_persistsInFlightSnapshot() async {
        await MyAppStore.clearStorage()
        MyAppTypeRegistry.shared.registerBuiltins()

        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let scope: ChatScope = .myApp(a.id)
        let tid = store.currentThreadId(for: scope)

        // Blackholed connect keeps the turn in flight while we inspect the cache.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 2
        let vm = ChatViewModel(
            store: store, memory: makeMemory(),
            settings: SettingsStore(backendURL: URL(string: "http://192.0.2.1/")!),
            registry: ToolRegistry(), scope: scope, threadId: tid,
            urlSession: URLSession(configuration: cfg), toolGateState: ToolGateState())

        vm.send("kill me mid-turn")

        #expect(await poll { TranscriptCache.loadSnapshot(tid)?.turnInFlight == true },
                "the send-time snapshot records the turn as in flight")
        vm.cancel()
    }

    @Test("coordinator persistAllForBackground snapshots every streaming session")
    func background_persistsStreamingSessions() async {
        await MyAppStore.clearStorage()
        MyAppTypeRegistry.shared.registerBuiltins()

        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let coord = ChatSessionCoordinator(
            store: store, memory: makeMemory(),
            settings: SettingsStore(backendURL: URL(string: "http://192.0.2.1/")!))
        let vm = coord.session(for: .myApp(a.id))
        let tid = vm.threadId

        vm.send("background me")
        #expect(await poll(timeout: .seconds(1)) { vm.isStreaming })

        coord.persistAllForBackground()

        #expect(await poll { TranscriptCache.loadSnapshot(tid)?.turnInFlight == true },
                "backgrounding snapshots the in-flight turn")
        vm.cancel()
    }

    // MARK: - apply-level guards

    @Test("cursorAdvanced events drive the applied replay cursor")
    func apply_tracksAppliedCursor() async {
        await MyAppStore.clearStorage()
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let vm = makeVM(store: store, scope: .myApp(a.id))

        #expect(vm.appliedEventSeq == nil)
        vm.apply(.cursorAdvanced(7))
        #expect(vm.appliedEventSeq == 7)
        vm.apply(.cursorAdvanced(9))
        #expect(vm.appliedEventSeq == 9)
    }

    @Test("assistantMessageEnd never truncates a hydrated head when the buffer only holds the tail")
    func apply_messageEnd_suffixGuard() async {
        await MyAppStore.clearStorage()
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let vm = makeVM(store: store, scope: .myApp(a.id))

        // Live stream: bubble accumulates "head", then the post-relaunch
        // session buffer only saw " tail".
        vm.apply(.assistantMessageStart(messageId: "m9"))
        vm.apply(.assistantMessageDelta(messageId: "m9", delta: "head"))
        vm.apply(.assistantMessageDelta(messageId: "m9", delta: " tail"))
        vm.apply(.assistantMessageEnd(messageId: "m9", text: " tail"))
        #expect(vm.bubbles.first(where: { $0.id == "m9" })?.text == "head tail",
                "a tail-only END must not truncate the accumulated text")

        // A genuinely divergent END (missed deltas) is still authoritative.
        vm.apply(.assistantMessageEnd(messageId: "m9", text: "authoritative full text"))
        #expect(vm.bubbles.first(where: { $0.id == "m9" })?.text == "authoritative full text")
    }
}
