import Foundation
import Testing
@testable import PupaApp

/// The derived per-app snapshot index: `metas()` must answer from a small
/// local cache instead of reading and parsing every snapshot file. The index
/// is never authoritative — these tests pin that it always validates against
/// the directory it derives from, and rebuilds rather than lying.
@MainActor
@Suite("Snapshot index")
struct SnapshotIndexTests {

    init() { TestStorage.activate() }

    /// A fresh app id with `count` recorded snapshots, `pins` of them pinned.
    /// Timestamps are strictly increasing so ordering is tie-free.
    private func seed(count: Int, pins: Int = 0) -> UUID {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "S", iconSystemName: "list.bullet", typeId: MyAppType.tracker.id)
        SnapshotStore.deleteAll(myApp.id)
        for i in 0..<count {
            var edited = myApp
            edited.name = "S rev \(i)"
            SnapshotStore.record(
                edited,
                reason: i < pins ? .pinned : .edit,
                label: i < pins ? "pin\(i)" : nil,
                now: Date(timeIntervalSince1970: 1_000_000 + Double(i)))
        }
        return myApp.id
    }

    @Test("metas reads the index, not the history")
    func metasReadsIndex() {
        let id = seed(count: 60)
        // Warm the index, then measure a cold-cache-free second call.
        _ = SnapshotStore.metas(id)

        DiskIO.reset()
        SnapshotStore.fullDecodeCount = 0
        let metas = SnapshotStore.metas(id)

        #expect(metas.count == 60)
        #expect(SnapshotStore.fullDecodeCount == 0)
        // One read: the index. The directory listing is not a `CloudDocument.read`.
        #expect(DiskIO.reads <= 2, "read \(DiskIO.reads) files to list 60 snapshots")
    }

    @Test("index self-heals when deleted")
    func indexSelfHealsWhenDeleted() {
        let id = seed(count: 12)
        let expected = SnapshotStore.metas(id)

        try? FileManager.default.removeItem(at: SnapshotStore.indexURL(id))
        let rebuilt = SnapshotStore.metas(id)

        #expect(rebuilt.map(\.id) == expected.map(\.id))
        #expect(FileManager.default.fileExists(atPath: SnapshotStore.indexURL(id).path))
    }

    @Test("index self-heals when a record lands behind its back")
    func indexSelfHealsWhenStale() {
        let id = seed(count: 8)
        _ = SnapshotStore.metas(id)

        // Copy an existing record under a new id — a write that bypasses
        // `record`, the way an iCloud merge can land one.
        let dir = SnapshotStore.dir(id)
        let existing = try! FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" }!
        try! FileManager.default.copyItem(
            at: existing, to: dir.appendingPathComponent("\(UUID().uuidString).json"))

        #expect(SnapshotStore.metas(id).count == 9)
    }

    @Test("index never lands in a mirrored subtree")
    func indexIsNotMirrored() {
        let id = seed(count: 3)
        _ = SnapshotStore.metas(id)

        let path = SnapshotStore.indexURL(id).standardizedFileURL.path
        for subtree in PupaStorage.mirroredSubtrees {
            let mirrored = PupaStorage.activeRoot
                .appendingPathComponent(subtree, isDirectory: true)
                .standardizedFileURL.path
            #expect(!path.hasPrefix(mirrored), "index would sync: \(path)")
        }
    }

    @Test("the pins gate reads no snapshot payloads")
    func pinsGateReadsNoPayloads() async {
        var ids: [UUID] = []
        for _ in 0..<5 { ids.append(seed(count: 20, pins: 3)) }
        for id in ids { _ = SnapshotStore.metas(id) }

        DiskIO.reset()
        SnapshotStore.fullDecodeCount = 0
        let any = await SnapshotStore.hasAnyPins()

        #expect(any)
        #expect(SnapshotStore.fullDecodeCount == 0)
        // Short-circuits on the first app with a pin; never opens a payload.
        #expect(DiskIO.bytesRead < 64_000, "gate read \(DiskIO.bytesRead) bytes")
    }

    @Test("recording an edit does not scale with history length")
    func recordDoesNotRescanHistory() {
        // `record` always walks its diff chain back to a base, so reads are
        // bounded by `baseInterval` — but it must NOT also pull every header,
        // which is what `head()` used to do (twice: once directly, once via
        // `prune`). Comparing a short and a long history pins that.
        func readsForOneEdit(historyLength: Int) -> Int {
            let id = seed(count: historyLength)
            _ = SnapshotStore.metas(id)
            var app = MyApp(id: id, name: "next", iconSystemName: "list.bullet",
                            typeId: MyAppType.tracker.id)
            app.name = "next edit"
            DiskIO.reset()
            SnapshotStore.record(app, reason: .edit,
                                 now: Date(timeIntervalSince1970: 2_000_000))
            return DiskIO.reads
        }

        let short = readsForOneEdit(historyLength: 20)
        let long = readsForOneEdit(historyLength: 60)

        #expect(long <= short + 4, "reads grew \(short) → \(long) with history length")
    }
}
