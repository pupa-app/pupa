import Foundation
import Testing
@testable import PupaApp

/// Covers `StorageMirror` — the local-canonical ↔ iCloud two-way mirror.
///
/// The pure `plan()` rule table is exercised directly (the safety-critical
/// core), and `converge()` is driven against isolated temp dirs — never the
/// process-wide `PupaStorage` overrides — so these run in parallel with other
/// suites without clobbering shared disk state.
@Suite("Storage mirror")
struct StorageMirrorTests {

    // MARK: - Helpers

    private func meta(_ content: String, _ date: Date = Date()) -> StorageMirror.Meta {
        StorageMirror.Meta(hash: StorageMirror.hash(Data(content.utf8)), modified: date)
    }

    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func put(_ root: URL, _ rel: String, _ content: String, mtime: Date? = nil) {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(content.utf8).write(to: url)
        if let mtime {
            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }

    private func get(_ root: URL, _ rel: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(rel))).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func exists(_ root: URL, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path)
    }

    /// Every file body found anywhere under `dir` (recursive).
    private func bodiesUnder(_ dir: URL) -> [String] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let url as URL in en where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            if let s = (try? Data(contentsOf: url)).flatMap({ String(data: $0, encoding: .utf8) }) { out.append(s) }
        }
        return out
    }

    // MARK: - Pure plan()

    @Test("plan: brand-new one-sided files push up / pull down (no baseline)")
    func planNewFiles() {
        let p = StorageMirror.plan(local: ["a.json": meta("A")], cloud: ["b.md": meta("B")], baseline: [:])
        #expect(p == [.pushUp("a.json"), .pullDown("b.md")])  // sorted by rel: a.json < b.md
    }

    @Test("plan: identical content on both sides is a no-op")
    func planIdentical() {
        let p = StorageMirror.plan(local: ["x": meta("same")], cloud: ["x": meta("same")], baseline: [:])
        #expect(p.isEmpty)
    }

    @Test("plan: a sequential edit (only local moved off baseline) pushes up — NOT a conflict")
    func planSequentialLocalEdit() {
        let base = StorageMirror.hash(Data("v1".utf8))
        let p = StorageMirror.plan(
            local: ["x": meta("v2")], cloud: ["x": meta("v1")], baseline: ["x": base])
        #expect(p == [.pushUp("x")])
    }

    @Test("plan: only-cloud-moved pulls down")
    func planSequentialCloudEdit() {
        let base = StorageMirror.hash(Data("v1".utf8))
        let p = StorageMirror.plan(
            local: ["x": meta("v1")], cloud: ["x": meta("v2")], baseline: ["x": base])
        #expect(p == [.pullDown("x")])
    }

    @Test("plan: both sides moved off baseline is a genuine conflict, newest wins")
    func planTrueConflict() {
        let base = StorageMirror.hash(Data("v0".utf8))
        let newer = Date(timeIntervalSince1970: 2000)
        let older = Date(timeIntervalSince1970: 1000)
        // local newer
        #expect(StorageMirror.plan(
            local: ["x": meta("L", newer)], cloud: ["x": meta("C", older)], baseline: ["x": base])
            == [.conflict(rel: "x", localNewer: true)])
        // cloud newer
        #expect(StorageMirror.plan(
            local: ["x": meta("L", older)], cloud: ["x": meta("C", newer)], baseline: ["x": base])
            == [.conflict(rel: "x", localNewer: false)])
    }

    @Test("plan: differing sides with no baseline are treated as a conflict")
    func planNoBaselineConflict() {
        let p = StorageMirror.plan(
            local: ["x": meta("L", Date(timeIntervalSince1970: 5))],
            cloud: ["x": meta("C", Date(timeIntervalSince1970: 1))], baseline: [:])
        #expect(p == [.conflict(rel: "x", localNewer: true)])
    }

    @Test("plan: cloud deletes an unchanged file → delete local")
    func planRemoteDelete() {
        let base = StorageMirror.hash(Data("same".utf8))
        let p = StorageMirror.plan(local: ["x": meta("same")], cloud: [:], baseline: ["x": base])
        #expect(p == [.deleteLocal("x")])
    }

    @Test("plan: local deletes an unchanged file → delete cloud")
    func planLocalDelete() {
        let base = StorageMirror.hash(Data("same".utf8))
        let p = StorageMirror.plan(local: [:], cloud: ["x": meta("same")], baseline: ["x": base])
        #expect(p == [.deleteCloud("x")])
    }

    @Test("plan: delete racing an edit keeps the edit (data survives)")
    func planDeleteVsEdit() {
        let base = StorageMirror.hash(Data("v0".utf8))
        // local deleted, cloud edited → keep cloud
        #expect(StorageMirror.plan(local: [:], cloud: ["x": meta("edited")], baseline: ["x": base])
            == [.pullDown("x")])
        // cloud deleted, local edited → keep local
        #expect(StorageMirror.plan(local: ["x": meta("edited")], cloud: [:], baseline: ["x": base])
            == [.pushUp("x")])
    }

    // MARK: - hash determinism

    @Test("hash is content-stable and distinguishes different bytes")
    func hashStable() {
        #expect(StorageMirror.hash(Data("abc".utf8)) == StorageMirror.hash(Data("abc".utf8)))
        #expect(StorageMirror.hash(Data("abc".utf8)) != StorageMirror.hash(Data("abd".utf8)))
    }

    // MARK: - converge() integration

    @Test("converge: a new local file is pushed to iCloud")
    func convergePushUp() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/apps/x.json", "hello")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(get(cloud, "state/apps/x.json") == "hello")
    }

    @Test("converge: a new cloud file is pulled down and reports a local change")
    func convergePullDown() {
        let (local, cloud) = (tmp(), tmp())
        put(cloud, "memories/note.md", "kale")
        let changed = StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(get(local, "memories/note.md") == "kale")
        #expect(changed == true)
    }

    @Test("converge: a second edit to an already-synced file does not spawn a conflict")
    func convergeSequentialEditNoConflict() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/index.json", "v1")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)   // baseline = v1
        put(local, "state/index.json", "v2")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(get(cloud, "state/index.json") == "v2")
        #expect(!exists(local, "conflicts"))                          // no conflict copy
    }

    @Test("converge: a genuine conflict keeps the newest and preserves the loser")
    func convergeConflictPreservesLoser() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/index.json", "base")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)   // baseline
        // Both edit; local is newer.
        put(local, "state/index.json", "LOCAL", mtime: Date(timeIntervalSince1970: 3000))
        put(cloud, "state/index.json", "CLOUD", mtime: Date(timeIntervalSince1970: 1000))
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        // Winner canonical on both sides…
        #expect(get(local, "state/index.json") == "LOCAL")
        #expect(get(cloud, "state/index.json") == "LOCAL")
        // …loser preserved somewhere under conflicts/.
        #expect(bodiesUnder(local.appendingPathComponent("conflicts")).contains("CLOUD"))
    }

    @Test("converge: when the cloud side wins, local is rewritten and a change is reported")
    func convergeConflictCloudWins() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/index.json", "base")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        put(local, "state/index.json", "LOCAL", mtime: Date(timeIntervalSince1970: 1000))
        put(cloud, "state/index.json", "CLOUD", mtime: Date(timeIntervalSince1970: 3000))
        let changed = StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(get(local, "state/index.json") == "CLOUD")
        #expect(changed == true)
        #expect(bodiesUnder(local.appendingPathComponent("conflicts")).contains("LOCAL"))
    }

    @Test("converge: a local delete propagates to iCloud")
    func convergeDeletePropagatesUp() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/apps/x.json", "a")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)   // baseline, cloud has it
        try? FileManager.default.removeItem(at: local.appendingPathComponent("state/apps/x.json"))
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(!exists(cloud, "state/apps/x.json"))
    }

    @Test("converge: a remote delete propagates to local")
    func convergeDeletePropagatesDown() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/apps/x.json", "a")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        try? FileManager.default.removeItem(at: cloud.appendingPathComponent("state/apps/x.json"))
        let changed = StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(!exists(local, "state/apps/x.json"))
        #expect(changed == true)
    }

    @Test("converge: a delete racing a remote edit restores the edit locally")
    func convergeDeleteVsEdit() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/apps/x.json", "base")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        try? FileManager.default.removeItem(at: local.appendingPathComponent("state/apps/x.json"))
        put(cloud, "state/apps/x.json", "edited")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(get(local, "state/apps/x.json") == "edited")
        #expect(get(cloud, "state/apps/x.json") == "edited")
    }

    @Test("converge: iCloud off (nil cloud root) is a no-op that leaves local data intact")
    func convergeICloudOff() {
        let local = tmp()
        put(local, "state/apps/x.json", "keep")
        let changed = StorageMirror.converge(localRoot: local, cloudRoot: nil)
        #expect(changed == false)
        #expect(get(local, "state/apps/x.json") == "keep")   // never hidden or lost
    }

    @Test("converge: a settled tree converges idempotently (second pass is a no-op)")
    func convergeIdempotent() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/index.json", "v1")
        put(cloud, "memories/a.md", "x")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)   // both propagate
        let changed = StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(changed == false)
        #expect(get(cloud, "state/index.json") == "v1")
        #expect(get(local, "memories/a.md") == "x")
    }
}
