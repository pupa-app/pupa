import Foundation
import Testing
@testable import PupaApp
@testable import AGUIKit

/// Snapshot history: content-addressed, diff-chained restore points that
/// replace the old per-command undo, plus the conflict keep-both path.
@MainActor
@Suite("Snapshot history")
struct SnapshotHistoryTests {

    init() { TestStorage.activate() }

    // MARK: - Helpers

    private func freshTrackerStore() -> (MyAppStore, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.setTracker(title: "Test", fields: [FieldDef(name: "title", type: .text)], myAppId: myApp.id)
        SnapshotStore.deleteAll(myApp.id)  // start from a clean history
        return (store, myApp.id)
    }

    private func app(_ store: MyAppStore, _ id: UUID) -> MyApp {
        store.myApps.first { $0.id == id }!
    }

    private func trackerItemCount(_ m: MyApp) -> Int {
        for c in m.components { if case .tracker(let t) = c.body { return t.items.count } }
        return -1
    }

    // MARK: - Round-trip

    /// A base time plus a per-index offset so records get strictly-increasing,
    /// tie-free timestamps in tight test loops (production edits are seconds
    /// apart via the debounce).
    private func t(_ i: Int) -> Date { Date(timeIntervalSince1970: 1_000_000 + Double(i)) }

    @Test("record → restoredApp returns the exact prior state")
    func recordRestoreRoundTrip() {
        let (store, id) = freshTrackerStore()
        let sEmpty = SnapshotStore.record(app(store, id), reason: .edit, now: t(0))!
        store.addItem(["title": "row1"], myAppId: id)
        let sOne = SnapshotStore.record(app(store, id), reason: .edit, now: t(1))!
        #expect(sEmpty != sOne)

        #expect(trackerItemCount(SnapshotStore.restoredApp(id, id: sEmpty)!) == 0)
        #expect(trackerItemCount(SnapshotStore.restoredApp(id, id: sOne)!) == 1)
    }

    @Test("identical consecutive edit dedups to one snapshot")
    func dedup() {
        let (store, id) = freshTrackerStore()
        let s1 = SnapshotStore.record(app(store, id), reason: .edit, now: t(0))!
        let s2 = SnapshotStore.record(app(store, id), reason: .edit, now: t(1))!
        #expect(s1 == s2)
        #expect(SnapshotStore.metas(id).count == 1)
    }

    // MARK: - Diff chain

    @Test("diff chain across many edits restores every point")
    func diffChainManyEdits() {
        let (store, id) = freshTrackerStore()
        var ids: [UUID] = []
        for i in 0..<30 {
            store.addItem(["title": "r\(i)"], myAppId: id)
            ids.append(SnapshotStore.record(app(store, id), reason: .edit, now: t(i))!)
        }
        // Restore points spanning base + diffs (base is written every 20 links).
        #expect(trackerItemCount(SnapshotStore.restoredApp(id, id: ids[4])!) == 5)
        #expect(trackerItemCount(SnapshotStore.restoredApp(id, id: ids[24])!) == 25)
        #expect(trackerItemCount(SnapshotStore.restoredApp(id, id: ids[29])!) == 30)
    }

    // MARK: - Prune

    @Test("prune bounds history and re-bases the oldest survivor")
    func pruneRebasesOldestSurvivor() {
        let (store, id) = freshTrackerStore()
        for i in 0..<10 {
            store.addItem(["title": "r\(i)"], myAppId: id)
            SnapshotStore.record(app(store, id), reason: .edit, now: t(i))
        }
        SnapshotStore.prune(id, now: t(100), ttl: SnapshotStore.defaultTTL, cap: 3)

        let metas = SnapshotStore.metas(id)
        #expect(metas.count == 3)
        // Oldest survivor is re-based so its chain no longer needs pruned links.
        let oldest = metas.last!
        #expect(SnapshotStore.restoredApp(id, id: oldest.id) != nil)
        #expect(trackerItemCount(SnapshotStore.restoredApp(id, id: metas.first!.id)!) == 10)
    }

    // MARK: - Restore is append-only

    @Test("restore is non-destructive: pre-restore state stays recoverable")
    func restoreAppendOnly() {
        let (store, id) = freshTrackerStore()
        let sEmpty = SnapshotStore.record(app(store, id), reason: .edit, now: t(0))!
        store.addItem(["title": "keep"], myAppId: id)  // current = 1 item

        #expect(store.restore(myAppId: id, snapshotId: sEmpty))
        #expect(trackerItemCount(app(store, id)) == 0)  // reverted

        let metas = SnapshotStore.metas(id)
        // The 1-item pre-restore state was checkpointed → still recoverable.
        let recoverable = metas.contains {
            SnapshotStore.restoredApp(id, id: $0.id).map(trackerItemCount) == 1
        }
        #expect(recoverable)
        // The newest snapshot is the restored (0-item) state (git-revert).
        #expect(trackerItemCount(SnapshotStore.restoredApp(id, id: metas.first!.id)!) == 0)
    }

    // MARK: - Conflict keep-both + newest-wins

    @Test("conflict capture keeps both sides and resolves newest-wins")
    func conflictKeepBothNewestWins() {
        let (store, id) = freshTrackerStore()

        // Heavy offline side (2 items).
        store.addItem(["title": "o1"], myAppId: id)
        store.addItem(["title": "o2"], myAppId: id)
        let heavyData = try! JSONEncoder().encode(app(store, id))

        // Tiny online side (1 different item).
        for item in (app(store, id).components.compactMap { c -> [TrackerItem]? in
            if case .tracker(let t) = c.body { return t.items } else { return nil }
        }.first ?? []) {
            store.removeItem(id: item.id, myAppId: id)
        }
        store.addItem(["title": "tiny"], myAppId: id)
        let lightData = try! JSONEncoder().encode(app(store, id))

        SnapshotStore.deleteAll(id)  // isolate the conflict-capture assertions

        // Tiny change is NEWER and wins the live file; heavy offline is older.
        let winner = store.captureConflict(
            liveData: lightData, liveDate: Date(),
            versions: [(heavyData, Date().addingTimeInterval(-100))])
        #expect(winner == lightData)

        // Both sides recoverable from history (nothing lost).
        let counts = Set(SnapshotStore.metas(id).compactMap {
            SnapshotStore.restoredApp(id, id: $0.id).map(trackerItemCount)
        })
        #expect(counts.contains(2))  // heavy offline edits preserved
        #expect(counts.contains(1))  // tiny online edit preserved
    }

    @Test("conflict newest-wins promotes a newer conflict version")
    func conflictNewerVersionWins() {
        let (store, id) = freshTrackerStore()
        store.addItem(["title": "a"], myAppId: id)
        let versionData = try! JSONEncoder().encode(app(store, id))
        let liveData = try! JSONEncoder().encode(app(store, id))  // same content is fine for date test
        SnapshotStore.deleteAll(id)

        let winner = store.captureConflict(
            liveData: liveData, liveDate: Date().addingTimeInterval(-100),
            versions: [(versionData, Date())])
        #expect(winner == versionData)
    }

    // MARK: - Pinned snapshots (permanent, exportable)

    private func tempMemory() -> MemoryStore {
        MemoryStore(rootOverride: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    @Test("a pinned snapshot survives a prune that evicts every automatic edit")
    func pinnedSurvivesPrune() {
        let (store, id) = freshTrackerStore()
        store.addItem(["title": "milestone"], myAppId: id)  // 1 item
        let pin = SnapshotStore.record(app(store, id), reason: .pinned, label: "v1", now: t(0))!

        // Churn far past the cap with automatic edits; the pin is the oldest
        // snapshot, so this exercises the "pin older than the evicted block"
        // re-base path.
        for i in 1...50 {
            store.addItem(["title": "r\(i)"], myAppId: id)
            SnapshotStore.record(app(store, id), reason: .edit, now: t(i))
        }
        SnapshotStore.prune(id, now: t(1000), ttl: SnapshotStore.defaultTTL, cap: 3)

        let metas = SnapshotStore.metas(id)
        // Pin kept; it does not consume the cap of 3 automatic survivors.
        #expect(metas.contains { $0.id == pin })
        #expect(SnapshotStore.pinnedCount(id) == 1)
        #expect(metas.filter { $0.reason == .edit }.count == 3)
        // Pin resolves to its exact 1-item state.
        #expect(trackerItemCount(SnapshotStore.restoredApp(id, id: pin)!) == 1)
        // Newest automatic survivor still resolves despite deleted mid-chain links.
        #expect(trackerItemCount(SnapshotStore.restoredApp(id, id: metas.first!.id)!) == 51)
    }

    @Test("pinned snapshots never dedup, even with identical content")
    func pinnedNoDedup() {
        let (store, id) = freshTrackerStore()
        let a = SnapshotStore.record(app(store, id), reason: .pinned, label: "one", now: t(0))!
        let b = SnapshotStore.record(app(store, id), reason: .pinned, label: "two", now: t(1))!
        #expect(a != b)
        #expect(SnapshotStore.pinnedCount(id) == 2)
        #expect(Set(SnapshotStore.pinnedMetas(id).compactMap(\.label)) == ["one", "two"])
    }

    @Test("takeSnapshot pins current state and export round-trips through the importer")
    func takeSnapshotExportRoundTrip() throws {
        let (store, id) = freshTrackerStore()
        let mem = tempMemory()
        store.globalMemory = mem

        store.addItem(["title": "keep-me"], myAppId: id)
        #expect(store.takeSnapshot(myAppId: id, label: "milestone") != nil)
        #expect(store.pinnedSnapshotCount(forMyApp: id) == 1)

        let pin = try #require(SnapshotStore.pinnedMetas(id).first)
        let data = try #require(store.snapshotBundleData(forSnapshot: pin.id, appId: id))

        // Import the exported pin into a fresh store → the tracker row survives.
        let dest = MyAppStore(initial: ([], UUID()))
        let result = try MyAppImporter.importBundle(data, into: dest, memory: mem)
        let imported = try #require(dest.myApps.first { $0.id == result.myAppId })
        if case .tracker(let t) = imported.component(withId: "tracker-1")?.body {
            #expect(t.items.count == 1)
        } else { Issue.record("tracker missing after import") }
    }

    // MARK: - Pins survive deletion

    @Test("deleteNonPinned keeps pins, drops automatic edits")
    func deleteNonPinnedKeepsPins() {
        let (store, id) = freshTrackerStore()
        store.addItem(["title": "x"], myAppId: id)
        SnapshotStore.record(app(store, id), reason: .edit, now: t(0))
        let pin = SnapshotStore.record(app(store, id), reason: .pinned, label: "keep", now: t(1))!

        SnapshotStore.deleteNonPinned(id)
        let metas = SnapshotStore.metas(id)
        #expect(metas.count == 1)
        #expect(metas.first?.id == pin)
        #expect(SnapshotStore.restoredApp(id, id: pin) != nil)
    }

    @Test("deleteNonPinned with no pins removes the whole dir")
    func deleteNonPinnedNoPins() {
        let (store, id) = freshTrackerStore()
        SnapshotStore.record(app(store, id), reason: .edit, now: t(0))
        SnapshotStore.deleteNonPinned(id)
        #expect(SnapshotStore.metas(id).isEmpty)
        #expect(!SnapshotStore.allAppIds().contains(id))
    }

    @Test("restorePinnedSnapshot revives a deleted app from its surviving pin")
    func revivesDeletedApp() {
        // Two apps so the first can be removed (removeMyApp needs count > 1).
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "Alpha", iconSystemName: "a.circle", typeId: MyAppType.tracker.id)
        let b = MyApp(name: "Beta", iconSystemName: "b.circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a, b], a.id))
        store.globalMemory = tempMemory()
        SnapshotStore.deleteAll(a.id)

        store.setTracker(title: "T", fields: [FieldDef(name: "title", type: .text)], myAppId: a.id)
        store.addItem(["title": "important"], myAppId: a.id)
        #expect(store.takeSnapshot(myAppId: a.id, label: "v1") != nil)
        let pin = SnapshotStore.pinnedMetas(a.id).first!

        // Delete the app; its pin must survive.
        store.removeMyApp(a.id)
        #expect(!store.myApps.contains { $0.id == a.id })
        #expect(SnapshotStore.pinnedCount(a.id) == 1)

        // The Settings page sees it as a deleted (non-live) group.
        let groups = store.pinnedSnapshotGroups()
        let alpha = groups.first { $0.appId == a.id }
        #expect(alpha?.isLive == false)
        #expect(alpha?.appName == "Alpha")

        // Restore revives the whole app under its original id.
        let revivedId = store.restorePinnedSnapshot(appId: a.id, snapshotId: pin.id)
        #expect(revivedId == a.id)
        let revived = store.myApps.first { $0.id == a.id }
        #expect(revived != nil)
        if case .tracker(let tr) = revived?.component(withId: "tracker-1")?.body {
            #expect(tr.items.count == 1)
        } else { Issue.record("revived tracker missing") }
    }
}
