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

    @Test("plan: the provisioning guard never pushes or wins the roster index")
    func planProvisioningIndexGuard() {
        // Brand-new local index, cloud absent → normally pushUp; guarded → no-op
        // (never clobber a cloud roster that just hasn't downloaded yet).
        #expect(StorageMirror.plan(
            local: ["index.json": meta("SEED")], cloud: [:], baseline: [:],
            protectIndexPush: true).isEmpty)
        // A genuine conflict on the index → normally newest-wins; guarded → the
        // cloud roster wins (pullDown), even though local is newer.
        let base = StorageMirror.hash(Data("v0".utf8))
        #expect(StorageMirror.plan(
            local: ["index.json": meta("LOCAL", Date(timeIntervalSince1970: 9999))],
            cloud: ["index.json": meta("CLOUD", Date(timeIntervalSince1970: 1))],
            baseline: ["index.json": base],
            protectIndexPush: true) == [.pullDown("index.json")])
        // A non-index file is unaffected by the guard.
        #expect(StorageMirror.plan(
            local: ["apps/x.json": meta("A")], cloud: [:], baseline: [:],
            protectIndexPush: true) == [.pushUp("apps/x.json")])
        // Guard off (default) → the index behaves like any other file.
        #expect(StorageMirror.plan(
            local: ["index.json": meta("SEED")], cloud: [:], baseline: [:])
            == [.pushUp("index.json")])
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

    @Test("converge: a remote delete propagates but quarantines the local bytes under conflicts/")
    func convergeRemoteDeleteQuarantines() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/apps/x.json", "precious")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        try? FileManager.default.removeItem(at: cloud.appendingPathComponent("state/apps/x.json"))
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(!exists(local, "state/apps/x.json"))
        #expect(bodiesUnder(local.appendingPathComponent("conflicts/state/apps/x.json")) == ["precious"])
    }

    @Test("converge: a cloud dir renamed away (conflict twin) deletes nothing irrecoverably and pulls the twin")
    func convergeCloudDirRenamedAway() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "memories/app/a.md", "note A")
        put(local, "memories/app/pupa/AGENTS.md", "prompt")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        // iCloud conflict-renames the whole dir: original rels vanish, twin appears.
        try? FileManager.default.moveItem(
            at: cloud.appendingPathComponent("memories/app"),
            to: cloud.appendingPathComponent("memories/app 2"))
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(get(local, "memories/app 2/a.md") == "note A")          // twin pulled
        let rescued = bodiesUnder(local.appendingPathComponent("conflicts/memories/app"))
        #expect(rescued.sorted() == ["note A", "prompt"])               // originals quarantined
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

    // MARK: - Reading quarantine back (issue #251)

    /// Quarantine one copy the way `preserveLoser` lays it out:
    /// `conflicts/<rel>/<stamp>`, mtime = preservation time.
    private func quarantine(_ local: URL, _ rel: String, _ body: String, at when: Date, stamp: String) {
        put(local, "conflicts/\(rel)/\(stamp)", body, mtime: when)
    }

    @Test("preservedFiles returns the newest copy per path, scoped to the prefix")
    func preservedFilesNewestPerPathAndScoped() {
        let local = tmp()
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        quarantine(local, "memories/mine/pupa/skills/a/SKILL.md", "v1", at: old, stamp: "s1.md")
        quarantine(local, "memories/mine/pupa/skills/a/SKILL.md", "v2", at: recent, stamp: "s2.md")
        quarantine(local, "memories/theirs/pupa/skills/b/SKILL.md", "not mine", at: recent, stamp: "s1.md")

        let found = StorageMirror.preservedFiles(
            underPrefix: "memories/mine", since: old, localRoot: local)

        #expect(Set(found.keys) == ["memories/mine/pupa/skills/a/SKILL.md"])
        #expect((try? Data(contentsOf: found.values.first!)).map { String(decoding: $0, as: UTF8.self) } == "v2")
    }

    @Test("preservedFiles ignores copies quarantined before the cutoff")
    func preservedFilesRespectsCutoff() {
        let local = tmp()
        quarantine(local, "memories/mine/a.md", "stale",
                   at: Date(timeIntervalSince1970: 1_000), stamp: "s1.md")

        let found = StorageMirror.preservedFiles(
            underPrefix: "memories/mine", since: Date(timeIntervalSince1970: 2_000), localRoot: local)

        #expect(found.isEmpty)
    }

    /// End-to-end: the mirror's own `.deleteLocal` quarantine is what the
    /// recovery reads, so the two halves have to agree on the layout.
    @Test("a memory file iCloud removed is readable back out of quarantine")
    func convergeDeleteIsRecoverable() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "memories/mine/pupa/skills/a/SKILL.md", "warmup skill")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        try? FileManager.default.removeItem(
            at: cloud.appendingPathComponent("memories/mine/pupa/skills/a/SKILL.md"))
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(!exists(local, "memories/mine/pupa/skills/a/SKILL.md"))

        let found = StorageMirror.preservedFiles(
            underPrefix: "memories/mine", since: Date(timeIntervalSinceNow: -60), localRoot: local)

        #expect(found.keys.contains("memories/mine/pupa/skills/a/SKILL.md"))
    }

    /// Losing the *same bytes* twice must stay recoverable. Dedup writes no
    /// second copy, so the first one's preservation time has to be refreshed —
    /// otherwise the recovery window (and the age prune) still measure from a
    /// loss that was already repaired.
    @Test("a repeat loss of unchanged content refreshes its preserved copy")
    func repeatLossRefreshesPreservedCopy() {
        let (local, cloud) = (tmp(), tmp())
        let rel = "memories/mine/pupa/skills/a/SKILL.md"

        put(local, rel, "warmup skill")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        try? FileManager.default.removeItem(at: cloud.appendingPathComponent(rel))
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(!exists(local, rel))

        // Age the quarantine: the first loss was long ago and already restored.
        let dir = local.appendingPathComponent("conflicts/\(rel)", isDirectory: true)
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -10 * 24 * 3600)], ofItemAtPath: u.path)
        }
        put(local, rel, "warmup skill")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(exists(cloud, rel))

        // Second loss, byte-identical.
        try? FileManager.default.removeItem(at: cloud.appendingPathComponent(rel))
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(!exists(local, rel))

        let found = StorageMirror.preservedFiles(
            underPrefix: "memories/mine", since: Date(timeIntervalSinceNow: -300), localRoot: local)

        #expect(found.keys.contains(rel))
    }

    // MARK: - Conflict-preservation budget

    private func t(_ ti: Double) -> Date { Date(timeIntervalSince1970: ti) }

    private func conflictCount(_ local: URL, _ rel: String) -> Int {
        let dir = local.appendingPathComponent("conflicts/\(rel)", isDirectory: true)
        return (((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }).count
    }

    /// Drive one genuine conflict on `state/index.json` with distinct loser
    /// content, local winning.
    private func makeConflict(_ local: URL, _ cloud: URL, local localBody: String, loser: String, at tick: Double) {
        put(local, "state/index.json", localBody, mtime: t(10_000 + tick))
        put(cloud, "state/index.json", loser, mtime: t(1_000))
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
    }

    @Test("conflict copies are local-only — never mirrored to iCloud")
    func conflictsNotMirrored() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/index.json", "base")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        makeConflict(local, cloud, local: "LOCAL", loser: "CLOUD", at: 1)
        #expect(exists(local, "conflicts"))    // preserved locally
        #expect(!exists(cloud, "conflicts"))   // but not synced up
    }

    @Test("an oscillating conflict re-presenting the same loser is deduped")
    func conflictDedup() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/index.json", "base")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        makeConflict(local, cloud, local: "L1", loser: "CLOUD", at: 1)
        makeConflict(local, cloud, local: "L2", loser: "CLOUD", at: 2)   // same loser bytes
        #expect(conflictCount(local, "state/index.json") == 1)
    }

    @Test("preserved copies for a path are capped at the newest N")
    func conflictCap() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/index.json", "base")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        for i in 0..<(StorageMirror.maxConflictCopiesPerPath + 3) {
            makeConflict(local, cloud, local: "L\(i)", loser: "C\(i)", at: Double(i))
        }
        #expect(conflictCount(local, "state/index.json") == StorageMirror.maxConflictCopiesPerPath)
    }

    @Test("preserved copies older than the max age are pruned on the next pass")
    func conflictAgePrune() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/index.json", "base")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        makeConflict(local, cloud, local: "LOCAL", loser: "CLOUD", at: 1)
        #expect(conflictCount(local, "state/index.json") == 1)

        // Backdate the copy beyond the max age, then a no-op converge prunes it.
        let dir = local.appendingPathComponent("conflicts/state/index.json", isDirectory: true)
        let old = Date(timeIntervalSinceNow: -StorageMirror.conflictMaxAge - 3600)
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
        }
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(!exists(local, "conflicts/state/index.json"))   // pruned + empty dir removed
    }

    // MARK: - iCloud materialization (placeholder → download → pull)

    @Test("materializedName: strips the .icloud placeholder wrapper, nil for real/hidden names")
    func materializedName() {
        #expect(StorageMirror.materializedName(forPlaceholder: ".Foo.json.icloud") == "Foo.json")
        #expect(StorageMirror.materializedName(forPlaceholder: ".notes.2024.md.icloud") == "notes.2024.md")
        #expect(StorageMirror.materializedName(forPlaceholder: "Foo.json") == nil)
        #expect(StorageMirror.materializedName(forPlaceholder: ".DS_Store") == nil)
        #expect(StorageMirror.materializedName(forPlaceholder: ".mirror-baseline.json") == nil)
        #expect(StorageMirror.materializedName(forPlaceholder: ".icloud") == nil)
    }

    @Test("scanCloud: a .icloud stub maps to its real sibling URL and stays out of the tree")
    func scanCloudStub() {
        let cloud = tmp()
        put(cloud, "memories/.Note.md.icloud", "stub")
        let scan = StorageMirror.scanCloud(cloud.appendingPathComponent("memories"))
        #expect(scan.notDownloaded.count == 1)
        #expect(scan.notDownloaded.first?.real.lastPathComponent == "Note.md")
        #expect(scan.tree.isEmpty)                          // stub never enters the tree map
    }

    @Test("scanCloud: a dir of only real files has nothing to resolve and lands in the tree")
    func scanCloudFastPath() {
        let cloud = tmp()
        put(cloud, "memories/note.md", "real")
        let scan = StorageMirror.scanCloud(cloud.appendingPathComponent("memories"))
        #expect(scan.notDownloaded.isEmpty)
        #expect(scan.tree["note.md"] != nil)               // one walk yields the tree too
    }

    @Test("kickDownloads: kicks a stub's download and returns it unresolved WITHOUT blocking")
    func kickDownloadsReturnsImmediately() {
        let cloud = tmp()
        let root = cloud.appendingPathComponent("memories")
        put(cloud, "memories/.Ghost.md.icloud", "stub")   // no real bytes will ever land
        let pending = StorageMirror.scanCloud(root).notDownloaded
        let start = Date()
        let unresolved = StorageMirror.kickDownloads(pending, cloudRoot: root)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0)                             // no bounded Thread.sleep wait
        #expect(unresolved == ["Ghost.md"])               // real name, subtree-relative
    }

    @Test("converge: an already-downloaded file next to its stale stub still pulls down")
    func convergePullsMaterializedBesideStub() {
        let (local, cloud) = (tmp(), tmp())
        put(cloud, "memories/note.md", "kale")            // real, materialized
        put(cloud, "memories/.note.md.icloud", "stub")    // stale placeholder alongside
        let changed = StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(get(local, "memories/note.md") == "kale")
        #expect(changed == true)
    }

    @Test("converge: an un-fetched stub is never fabricated locally and is not a change")
    func convergeUnfetchedStubIsNoop() {
        let (local, cloud) = (tmp(), tmp())
        put(cloud, "memories/.Ghost.md.icloud", "stub")   // no real bytes will ever land
        let changed = StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(!exists(local, "memories/Ghost.md"))       // never fabricated locally
        #expect(changed == false)
    }

    @Test("converge: an evicted (placeholder-only) cloud file is NOT mistaken for a remote delete")
    func convergeEvictionDoesNotDeleteLocal() {
        let (local, cloud) = (tmp(), tmp())
        put(local, "state/apps/x.json", "keep")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)   // pushUp → baseline + real cloud copy
        // iOS evicts the cloud copy back to a placeholder stub.
        try? FileManager.default.removeItem(at: cloud.appendingPathComponent("state/apps/x.json"))
        put(cloud, "state/apps/.x.json.icloud", "stub")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(get(local, "state/apps/x.json") == "keep")           // survived — deleteLocal suppressed
    }

    @Test("converge: a seeded local file never clobbers a not-yet-downloaded cloud placeholder")
    func convergePushUpSuppressedForPlaceholder() {
        let (local, cloud) = (tmp(), tmp())
        // Fresh device: local holds only a just-seeded index, no baseline.
        put(local, "state/index.json", "SEEDED-DEFAULT")
        // The real cloud index exists but hasn't downloaded — an .icloud stub.
        put(cloud, "state/.index.json.icloud", "stub")
        StorageMirror.converge(localRoot: local, cloudRoot: cloud)
        #expect(!exists(cloud, "state/index.json"))          // pushUp skipped — placeholder untouched
        #expect(exists(cloud, "state/.index.json.icloud"))   // stub intact for its download to land
    }
}
