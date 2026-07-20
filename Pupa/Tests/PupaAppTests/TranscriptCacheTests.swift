import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Serves a single canned response for the transcript endpoint
/// (`GET /db/threads/<id>/messages`) so `loadHistoryIfNeeded` can be driven
/// with a controlled backend reply (empty vs. populated).
final class TranscriptMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: Data = Data("[]".utf8)
    nonisolated(unsafe) static var status: Int = 200

    static func reset() { body = Data("[]".utf8); status = 200 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Tests for the on-device transcript cache (`TranscriptCache`) and the
/// cache-first / never-clobber load path in `ChatViewModel.loadHistoryIfNeeded`.
///
/// Disk-backed: `TestStorage.activate()` + `await MyAppStore.clearStorage()`
/// isolate each test to a temp state root, per the shared-root serial rule.
@MainActor
@Suite("Transcript cache", .serialized)
struct TranscriptCacheTests {

    init() { TestStorage.activate() }

    private func makeMemory() -> MemoryStore {
        MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pupa-tests-\(UUID().uuidString)"))
    }

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [TranscriptMockURLProtocol.self]
        cfg.timeoutIntervalForRequest = 5
        return URLSession(configuration: cfg)
    }

    private func poll(timeout: Duration = .seconds(2), _ cond: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if cond() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Codable

    @Test("ChatBubble round-trips through Codable with all member kinds")
    func chatBubble_codableRoundTrip() throws {
        let bubbles: [ChatBubble] = [
            ChatBubble(role: .user, text: "hi", imagesData: [Data([1, 2, 3])]),
            ChatBubble(role: .assistant, text: "hello"),
            ChatBubble(role: .toolRound, toolEntries: [
                ToolCallEntry(id: "c1", name: "addComponent", argsJSON: "{}",
                              resultText: "ok", state: .done),
            ]),
            ChatBubble(role: .humanQuestion, humanQuestions: [
                HumanQuestionRow(question: "Which?", options: ["A", "B"]),
            ]),
            ChatBubble(role: .assistant, chartSnapshot: ChatChartSnapshot(
                title: "T", kind: .bar, series: [])),
        ]
        let data = try JSONEncoder().encode(bubbles)
        let decoded = try JSONDecoder().decode([ChatBubble].self, from: data)
        #expect(decoded == bubbles)
    }

    // MARK: - Cache primitives

    @Test("save then load returns the same bubbles; delete clears; unknown id is empty")
    func saveLoadDelete() async {
        await MyAppStore.clearStorage()
        let id = "thread-1"
        #expect(TranscriptCache.load(id).isEmpty, "unknown id → empty")

        let bubbles = [ChatBubble(role: .user, text: "one"),
                       ChatBubble(role: .assistant, text: "two")]
        TranscriptCache.save(bubbles, threadId: id)
        #expect(TranscriptCache.load(id) == bubbles)

        TranscriptCache.delete(id)
        #expect(TranscriptCache.load(id).isEmpty)
    }

    @Test("save([]) writes no file — never masks a real backend transcript")
    func saveEmpty_writesNothing() async {
        await MyAppStore.clearStorage()
        let id = "empty-thread"
        TranscriptCache.save([], threadId: id)
        #expect(!FileManager.default.fileExists(atPath: TranscriptCache.url(id).path))
    }

    // MARK: - Never-clobber on load

    @Test("Empty backend response keeps the cached render (never-clobber)")
    func load_emptyBackend_keepsCache() async {
        await MyAppStore.clearStorage()
        TranscriptMockURLProtocol.reset() // backend returns []
        MyAppTypeRegistry.shared.registerBuiltins()

        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let scope: ChatScope = .myApp(a.id)
        let tid = store.currentThreadId(for: scope)
        let cached = [ChatBubble(role: .user, text: "remembered"),
                      ChatBubble(role: .assistant, text: "prior reply")]
        TranscriptCache.save(cached, threadId: tid)

        let vm = ChatViewModel(
            store: store, memory: makeMemory(),
            settings: SettingsStore(backendURL: URL(string: "http://mock.test/")!),
            registry: ToolRegistry(), scope: scope, threadId: tid,
            urlSession: mockSession(), toolGateState: ToolGateState())

        vm.loadHistoryIfNeeded()
        #expect(vm.bubbles == cached, "cache renders synchronously")
        // Let the backend fetch resolve; an empty reply must not clear the cache.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(vm.bubbles == cached, "empty backend response must not clobber the cache")
    }

    @Test("Populated backend response overrides the cache (backend wins)")
    func load_populatedBackend_overridesCache() async {
        await MyAppStore.clearStorage()
        TranscriptMockURLProtocol.reset()
        TranscriptMockURLProtocol.body = Data("""
        [{"role":"human","content":"from backend","tool_calls":[]}]
        """.utf8)
        MyAppTypeRegistry.shared.registerBuiltins()

        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let scope: ChatScope = .myApp(a.id)
        let tid = store.currentThreadId(for: scope)
        TranscriptCache.save([ChatBubble(role: .user, text: "stale cache")], threadId: tid)

        let vm = ChatViewModel(
            store: store, memory: makeMemory(),
            settings: SettingsStore(backendURL: URL(string: "http://mock.test/")!),
            registry: ToolRegistry(), scope: scope, threadId: tid,
            urlSession: mockSession(), toolGateState: ToolGateState())

        vm.loadHistoryIfNeeded()
        await poll { vm.bubbles.first?.text == "from backend" }
        #expect(vm.bubbles.count == 1)
        #expect(vm.bubbles.first?.text == "from backend", "backend transcript wins when non-empty")
    }

    // MARK: - Cleanup hooks

    @Test("removeThread deletes its transcript cache file")
    func removeThread_deletesCache() async {
        await MyAppStore.clearStorage()
        MyAppTypeRegistry.shared.registerBuiltins()
        let t0 = ChatThread(id: "t0"), t1 = ChatThread(id: "t1")
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id,
                      threads: [t0, t1], currentThreadId: "t1")
        let store = MyAppStore(initial: ([a], a.id))
        TranscriptCache.save([ChatBubble(role: .user, text: "x")], threadId: "t0")

        store.removeThread("t0", for: .myApp(a.id))

        #expect(TranscriptCache.load("t0").isEmpty)
    }

    @Test("Cap eviction deletes the evicted threads' transcript files")
    func capEviction_deletesCache() async {
        await MyAppStore.clearStorage()
        MyAppTypeRegistry.shared.registerBuiltins()
        let base = Date(timeIntervalSince1970: 1_000_000)
        let threads = (0..<4).map { ChatThread(id: "t\($0)", title: "t\($0)",
                                               createdAt: base.addingTimeInterval(Double($0))) }
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id,
                      threads: threads, currentThreadId: "t3")
        let store = MyAppStore(initial: ([a], a.id))
        for t in threads { TranscriptCache.save([ChatBubble(role: .user, text: t.id)], threadId: t.id) }
        store.threadCapBytes = { 1 } // force eviction down to the floor

        store.pruneAllThreads()

        // Only the newest (t3) survives; the rest lose their caches.
        #expect(TranscriptCache.load("t3").isEmpty == false)
        #expect(TranscriptCache.load("t0").isEmpty)
        #expect(TranscriptCache.load("t1").isEmpty)
        #expect(TranscriptCache.load("t2").isEmpty)
    }

    @Test("removeMyApp deletes every one of its threads' transcript files")
    func removeMyApp_deletesAllCaches() async {
        await MyAppStore.clearStorage()
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id,
                      threads: [ChatThread(id: "a0"), ChatThread(id: "a1")], currentThreadId: "a1")
        let b = MyApp(name: "B", iconSystemName: "square", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a, b], a.id))
        TranscriptCache.save([ChatBubble(role: .user, text: "x")], threadId: "a0")
        TranscriptCache.save([ChatBubble(role: .user, text: "y")], threadId: "a1")

        store.removeMyApp(a.id)

        #expect(TranscriptCache.load("a0").isEmpty)
        #expect(TranscriptCache.load("a1").isEmpty)
    }
}
