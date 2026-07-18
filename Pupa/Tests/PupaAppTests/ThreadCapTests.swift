import Foundation
import Testing
@testable import PupaApp

/// On-disk `index.json` shape, mirroring the private `MyAppStore.IndexFile`
/// (only the fields `load()` re-points). Encoded with a plain `JSONEncoder` —
/// the exact inverse of `load()`'s plain `JSONDecoder` — so a fresh
/// `MyAppStore()` decodes it as a real index. Optional index fields are omitted.
private struct IndexBlob: Encodable {
    var order: [UUID]
    var activeId: UUID
    var memoryThreads: [ChatThread]
    var memoryCurrentThreadId: String
}

/// Tests for the per-MyApp chat-storage cap: `MyAppStore.enforceThreadCap` /
/// `pruneAllThreads`, driven by the `threadCapBytes` closure. Eviction drops
/// the OLDEST threads (front of the array) when a scope exceeds the byte cap,
/// while always protecting the newest and the current thread and never
/// emptying a scope.
///
/// Fully in-memory (`MyAppStore(initial:)`); `TestStorage.activate()` only so
/// the `persist()` inside prune writes to a temp root, never real app data.
@MainActor
@Suite("MyAppStore thread storage cap", .serialized)
struct ThreadCapTests {

    init() { TestStorage.activate() }

    /// A MyApp seeded with `n` threads `t0…t(n-1)` (oldest → newest by array
    /// order and by `createdAt`), with `currentIndex` marked current.
    private func appWithThreads(_ n: Int, currentIndex: Int) -> MyApp {
        MyAppTypeRegistry.shared.registerBuiltins()
        let base = Date(timeIntervalSince1970: 1_000_000)
        let threads = (0..<n).map { i in
            ChatThread(id: "t\(i)", title: "Thread number \(i)",
                       createdAt: base.addingTimeInterval(Double(i)))
        }
        return MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id,
                     threads: threads, currentThreadId: threads[currentIndex].id)
    }

    private func store(_ app: MyApp) -> MyAppStore {
        MyAppStore(initial: ([app], app.id))
    }

    // MARK: - No cap

    @Test("No cap set → addThread never evicts (count grows monotonically)")
    func noCap_neverEvicts() {
        let app = appWithThreads(4, currentIndex: 3)
        let s = store(app)
        let scope = ChatScope.myApp(app.id)
        #expect(s.threadCapBytes == nil)
        s.addThread(for: scope)
        s.addThread(for: scope)
        #expect(s.threads(for: scope).count == 6)
    }

    // MARK: - addThread enforcement

    @Test("addThread evicts oldest when the new thread pushes the scope over cap")
    func addThread_evictsOldestOverCap() {
        let app = appWithThreads(5, currentIndex: 4)
        let s = store(app)
        let scope = ChatScope.myApp(app.id)
        let existing = s.threads(for: scope)
        // Cap = room for ~3 threads worth of metadata.
        let cap = existing.suffix(3).reduce(0) { $0 + MyAppStore.threadEncodedSize($1) }
        s.threadCapBytes = { cap }

        let newId = s.addThread(for: scope)

        let after = s.threads(for: scope)
        #expect(after.count < 6, "adding over the cap must evict, not just append")
        #expect(after.contains { $0.id == newId }, "the just-added thread is never evicted")
        #expect(after.last?.id == newId)
        #expect(s.currentThreadId(for: scope) == newId)
        // Oldest goes first.
        #expect(!after.contains { $0.id == "t0" })
    }

    // MARK: - Floor

    @Test("Tiny cap converges to a single thread (never empties the scope)")
    func tinyCap_keepsFloorOfOne() {
        let app = appWithThreads(6, currentIndex: 5) // current = newest
        let s = store(app)
        let scope = ChatScope.myApp(app.id)
        s.threadCapBytes = { 1 } // one byte — impossibly small

        s.pruneAllThreads()

        let after = s.threads(for: scope)
        #expect(after.count == 1)
        #expect(after[0].id == "t5", "the newest survives")
        #expect(s.currentThreadId(for: scope) == "t5")
    }

    // MARK: - Protection of the current thread

    @Test("An old current thread is protected and survivor order is preserved")
    func oldCurrent_protected_orderPreserved() {
        let app = appWithThreads(6, currentIndex: 0) // current = OLDEST
        let s = store(app)
        let scope = ChatScope.myApp(app.id)
        s.threadCapBytes = { 1 } // force maximum eviction

        s.pruneAllThreads()

        let after = s.threads(for: scope)
        let ids = after.map(\.id)
        #expect(ids.contains("t0"), "the current thread survives even when oldest")
        #expect(ids.contains("t5"), "the newest always survives")
        // Survivors keep original (ascending) array order — no reshuffle.
        #expect(ids == ids.sorted())
        #expect(s.currentThreadId(for: scope) == "t0")
    }

    // MARK: - Exact-fit boundary

    @Test("Cap equal to the K newest threads keeps exactly those K")
    func exactFit_keepsExactlyKNewest() {
        let app = appWithThreads(6, currentIndex: 5) // current = newest, not old
        let s = store(app)
        let scope = ChatScope.myApp(app.id)
        let threads = s.threads(for: scope) // t0…t5
        let newestFour = threads.suffix(4)
        let cap = newestFour.reduce(0) { $0 + MyAppStore.threadEncodedSize($1) }
        s.threadCapBytes = { cap }

        s.pruneAllThreads()

        let after = s.threads(for: scope)
        #expect(after.map(\.id) == ["t2", "t3", "t4", "t5"])
    }

    // MARK: - Memory scope parity

    @Test("Cap applies to the memory scope too")
    func memoryScope_capped() {
        let app = appWithThreads(1, currentIndex: 0)
        let s = store(app)
        // Seed several memory threads with no cap, then clamp hard.
        for _ in 0..<4 { s.addThread(for: .memory) }
        #expect(s.memoryThreads.count == 5)
        s.threadCapBytes = { 1 }

        s.pruneAllThreads()

        #expect(s.memoryThreads.count == 1)
        #expect(s.memoryThreads.contains { $0.id == s.memoryCurrentThreadId })
    }

    // MARK: - Cross-device repoint at load
    //
    // When the cap prunes a scope's *current* thread on one device and that
    // edit syncs here, this device's stored `currentThreadId` dangles (names a
    // thread that no longer exists). `load()` must re-point it to the newest
    // survivor so the UI never opens a dead conversation. These drive the real
    // on-disk `load()` path — the seed writes raw `index.json` + app files, then
    // a fresh `MyAppStore()` decodes and re-points them.

    /// Write one app file + `index.json` straight to the on-disk state root,
    /// bypassing the store, so the next `MyAppStore()` runs its `load()` on them.
    private func seedDisk(app: MyApp, memoryThreads: [ChatThread], memoryCurrent: String) throws {
        let enc = JSONEncoder() // plain — inverse of load()'s JSONDecoder()
        let stateRoot = PupaStorage.stateRoot
        try CloudDocument.write(
            enc.encode(app),
            to: stateRoot.appendingPathComponent("apps").appendingPathComponent("\(app.id.uuidString).json"))
        let index = IndexBlob(order: [app.id], activeId: app.id,
                              memoryThreads: memoryThreads, memoryCurrentThreadId: memoryCurrent)
        try CloudDocument.write(enc.encode(index), to: stateRoot.appendingPathComponent("index.json"))
    }

    @Test("load() re-points a dangling myApp currentThreadId to the newest thread")
    func load_repointsDanglingMyAppCurrent() async throws {
        await MyAppStore.clearStorage()
        var app = appWithThreads(4, currentIndex: 3) // threads t0…t3
        app.currentThreadId = "ghost-pruned-by-peer" // names no surviving thread
        try seedDisk(app: app, memoryThreads: [ChatThread(id: "m0")], memoryCurrent: "m0")

        let store = MyAppStore() // default init → load() → repoint

        #expect(store.currentThreadId(for: .myApp(app.id)) == "t3", "re-points to the newest surviving thread")
        #expect(store.threads(for: .myApp(app.id)).count == 4, "only current is re-pointed — no thread is dropped")
    }

    @Test("load() re-points a dangling memoryCurrentThreadId to the newest memory thread")
    func load_repointsDanglingMemoryCurrent() async throws {
        await MyAppStore.clearStorage()
        let app = appWithThreads(1, currentIndex: 0)
        let base = Date(timeIntervalSince1970: 3_000_000)
        let mem = (0..<3).map { ChatThread(id: "m\($0)", title: "m\($0)",
                                           createdAt: base.addingTimeInterval(Double($0))) }
        try seedDisk(app: app, memoryThreads: mem, memoryCurrent: "ghost")

        let store = MyAppStore()

        #expect(store.memoryCurrentThreadId == "m2", "re-points memory current to the newest survivor")
        #expect(store.memoryThreads.count == 3)
    }

    @Test("load() leaves a still-valid current untouched")
    func load_keepsValidCurrent() async throws {
        await MyAppStore.clearStorage()
        let app = appWithThreads(3, currentIndex: 1) // current = t1, a real thread
        try seedDisk(app: app, memoryThreads: [ChatThread(id: "m0")], memoryCurrent: "m0")

        let store = MyAppStore()

        #expect(store.currentThreadId(for: .myApp(app.id)) == "t1", "a valid current is not moved")
        #expect(store.memoryCurrentThreadId == "m0")
    }

    // MARK: - Per-app independence

    @Test("pruneAllThreads caps each MyApp independently")
    func pruneAllThreads_perApp() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let base = Date(timeIntervalSince1970: 2_000_000)
        func mk(_ name: String, _ n: Int) -> MyApp {
            let ts = (0..<n).map { ChatThread(id: "\(name)\($0)", title: "t \($0)",
                                              createdAt: base.addingTimeInterval(Double($0))) }
            return MyApp(name: name, iconSystemName: "circle", typeId: MyAppType.tracker.id,
                         threads: ts, currentThreadId: ts.last!.id)
        }
        let a = mk("A", 6)
        let b = mk("B", 3)
        let s = MyAppStore(initial: ([a, b], a.id))
        s.threadCapBytes = { 1 }

        s.pruneAllThreads()

        #expect(s.threads(for: .myApp(a.id)).count == 1)
        #expect(s.threads(for: .myApp(b.id)).count == 1)
    }
}
