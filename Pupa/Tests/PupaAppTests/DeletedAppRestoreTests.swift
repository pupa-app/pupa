import Foundation
import Testing
@testable import PupaApp

/// Deleting a MyApp must leave a restore point and a labelled tombstone, so
/// Settings ▸ Recently deleted can list it and bring it back. A delete used to
/// drop the body with nothing capturing it: silent and final on every device.
@MainActor
@Suite("Deleted MyApp restore", .serialized)
struct DeletedAppRestoreTests {

    init() { TestStorage.activate() }

    /// Shared temp root across suites, so start from a clean state tree —
    /// stale tombstones from a neighbouring suite would show up in
    /// `deletedMyApps()`.
    private func twoAppStore() async -> (MyAppStore, UUID, UUID) {
        await MyAppStore.clearStorage()
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "Dating help", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let b = MyApp(name: "Flight search", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a, b], a.id))
        store.setTracker(title: "T", fields: [FieldDef(name: "title", type: .text)], myAppId: a.id)
        return (store, a.id, b.id)
    }

    @Test("a deleted app is listed with its name and is restorable")
    func deleteListsRestorableApp() async {
        let (store, a, _) = await twoAppStore()
        store.removeMyApp(a)

        let deleted = MyAppStore.deletedMyApps()
        #expect(deleted.map(\.id) == [a])
        #expect(deleted.first?.name == "Dating help")
        #expect(deleted.first?.isRestorable == true)
    }

    @Test("restore brings the app back into the roster")
    func restoreReturnsApp() async {
        let (store, a, b) = await twoAppStore()
        store.removeMyApp(a)
        #expect(store.myApps.map(\.id) == [b])

        #expect(store.restoreDeletedMyApp(a))

        let ids: Set<UUID> = Set(store.myApps.map(\.id))
        #expect(ids == Set([a, b]))
        #expect(store.myApp(withId: a)?.name == "Dating help")
    }

    @Test("restore clears the tombstone so a reload can't re-suppress the app")
    func restoreClearsTombstone() async {
        let (store, a, _) = await twoAppStore()
        store.removeMyApp(a)
        #expect(store.restoreDeletedMyApp(a))

        #expect(MyAppStore.deletedMyApps().isEmpty)
        // The union-load path is what re-suppressed restored apps before: prove
        // a fresh store built from the same disk still sees it.
        let reloaded = MyAppStore()
        #expect(reloaded.myApps.contains { $0.id == a })
    }

    @Test("restoring an app that is already in the roster is a no-op")
    func restoreIsIdempotent() async {
        let (store, a, _) = await twoAppStore()
        store.removeMyApp(a)
        #expect(store.restoreDeletedMyApp(a))
        #expect(store.restoreDeletedMyApp(a) == false)
        #expect(store.myApps.filter { $0.id == a }.count == 1)
    }

    @Test("an unknown id has no restore point")
    func unknownIdNotRestorable() async {
        let (store, _, _) = await twoAppStore()
        #expect(store.restoreDeletedMyApp(UUID()) == false)
    }

    @Test("restore clears the local-delete marker so a later sync removal still advises")
    func restoreClearsUserInitiatedMarker() async {
        let (store, a, _) = await twoAppStore()
        store.removeMyApp(a)
        #expect(store.restoreDeletedMyApp(a))

        // Another device deletes it for real. Because the id was restored, this
        // is NOT the delete the user made here — it must raise the notice.
        let other = MyAppStore()
        other.removeMyApp(a)
        await store.reloadFromDisk()

        #expect(store.pendingSyncRemoval?.ids == [a])
    }

    // MARK: - Every tombstoned app is restorable

    /// A tombstone arriving from another device suppresses the local body
    /// before any snapshot has necessarily synced with it. The body itself is
    /// a perfectly good restore source while it's still on disk.
    @Test("a tombstoned app is restorable from its on-disk body with no snapshot")
    func bodyOnDiskIsARestoreSource() async {
        let (store, a, _) = await twoAppStore()
        MyAppStore.writeTombstone(a, name: "Dating help")   // remote delete lands
        SnapshotStore.deleteAll(a)                          // its snapshot hasn't synced
        _ = store

        let listed = MyAppStore.deletedMyApps().first { $0.id == a }
        #expect(listed?.isRestorable == true)
        #expect(listed?.name == "Dating help")
    }

    /// The sweep reaps a tombstoned body unconditionally, so it must hand that
    /// body to the snapshot store on the way out — otherwise a remote delete
    /// becomes unrecoverable here the moment the sweep runs.
    @Test("the orphan sweep captures a restore point before reaping a tombstoned body")
    func sweepCapturesRestorePointBeforeReaping() async {
        let (store, a, _) = await twoAppStore()
        MyAppStore.writeTombstone(a, name: "Dating help")
        SnapshotStore.deleteAll(a)
        _ = store

        MyAppStore.sweepOrphanAppFiles(keeping: [])
        #expect(SnapshotStore.head(a) != nil, "body must be captured, not just deleted")

        let fresh = MyAppStore()
        #expect(!fresh.myApps.contains { $0.id == a })      // still suppressed
        #expect(fresh.restoreDeletedMyApp(a))
        #expect(fresh.myApp(withId: a)?.name == "Dating help")
    }

    @Test("restore falls back to an older snapshot when the newest is corrupt")
    func restoreFallsBackPastCorruptHead() async {
        let (store, a, _) = await twoAppStore()
        guard let app = store.myApp(withId: a) else { Issue.record("missing app"); return }
        SnapshotStore.record(app, reason: .pinned, label: "keep")
        store.removeMyApp(a)

        // Corrupt the newest record (the `.deleted` one written on the way out).
        guard let head = SnapshotStore.head(a) else { Issue.record("no head"); return }
        try? Data("{ not json".utf8).write(to: SnapshotStore.url(a, head.id))

        #expect(store.restoreDeletedMyApp(a))
        #expect(store.myApp(withId: a)?.name == "Dating help")
    }

    @Test("gcTombstones drops the restore point it was holding once the tombstone ages out")
    func gcReapsOrphanedRestorePoint() async {
        let (store, a, _) = await twoAppStore()
        store.removeMyApp(a)
        #expect(SnapshotStore.head(a) != nil)

        _ = MyAppStore.gcTombstones(ttl: -1)                // force every tombstone to age out

        #expect(MyAppStore.deletedMyApps().isEmpty)
        #expect(SnapshotStore.head(a) == nil, "orphan restore point must go with the tombstone")
    }

    @Test("gcTombstones keeps a user pin when it reaps the restore point")
    func gcKeepsPins() async {
        let (store, a, _) = await twoAppStore()
        guard let app = store.myApp(withId: a) else { Issue.record("missing app"); return }
        SnapshotStore.record(app, reason: .pinned, label: "keep")
        store.removeMyApp(a)

        _ = MyAppStore.gcTombstones(ttl: -1)

        #expect(SnapshotStore.metas(a).map(\.reason) == [.pinned])
    }

    @Test("restoring an app that was archived brings it back visible")
    func restoreUnarchives() async {
        let (store, a, _) = await twoAppStore()
        store.setMyAppArchived(a, true)
        store.removeMyApp(a)

        #expect(store.restoreDeletedMyApp(a))
        // Otherwise the restore lands in Settings ▸ Archive: the row leaves
        // this list and the app shows up nowhere the user was looking.
        #expect(store.myApp(withId: a)?.isArchived == false)
        #expect(store.visibleMyApps.contains { $0.id == a })
    }

    /// `persist()` is a no-op while provisioning, but `clearTombstone` isn't —
    /// restoring then would write no body and drop the marker, losing the app
    /// from both the roster and this list.
    @Test("restore is refused while provisioning, so the tombstone survives")
    func restoreRefusedWhileProvisioning() async throws {
        let (store, a, _) = await twoAppStore()
        store.removeMyApp(a)
        #expect(MyAppStore.deletedMyApps().contains { $0.id == a })

        // Relaunch into a provisioning store: an empty local roster (index and
        // bodies gone) with the tombstone tree intact and iCloud active.
        let fm = FileManager.default
        try? fm.removeItem(at: PupaStorage.stateRoot.appendingPathComponent("index.json"))
        try? fm.removeItem(at: PupaStorage.stateRoot.appendingPathComponent("apps"))
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)

        try await TestStorage.withCloudMirror(cloud) {
            let provisioning = MyAppStore()
            #expect(provisioning.isProvisioning)
            #expect(provisioning.restoreDeletedMyApp(a) == false)
            #expect(MyAppStore.deletedMyApps().contains { $0.id == a })
        }
    }

    @Test("hasTombstones tracks the listing without resolving restore sources")
    func hasTombstonesTracksListing() async {
        let (store, a, _) = await twoAppStore()
        #expect(MyAppStore.hasTombstones() == false)

        store.removeMyApp(a)
        #expect(MyAppStore.hasTombstones())

        #expect(store.restoreDeletedMyApp(a))
        #expect(MyAppStore.hasTombstones() == false)
    }

    @Test("the cloud-roster retry clears the waiting flag when it gives up")
    func retryClearsWaitingFlagOnTimeout() async {
        let (store, _, _) = await twoAppStore()
        // Empty the disk so `load()` keeps reporting "no roster" and the retry
        // runs to its deadline instead of adopting on the first pass.
        await MyAppStore.clearStorage()
        store.beginAwaitingCloudRoster(timeout: .milliseconds(120), interval: .milliseconds(10))
        #expect(store.awaitingCloudRoster)

        await store.cloudRosterRetry?.value

        #expect(store.awaitingCloudRoster == false, "a give-up must not read as 'still restoring'")
    }

    // MARK: - The restore point doesn't outlive its use

    /// `.deleted` records are exempt from TTL *and* cap, and `gcTombstones` —
    /// their only collector — works off the tombstone a restore just cleared.
    /// Without an explicit drop, every cycle strands a full base forever.
    @Test("delete/restore cycles don't accumulate permanent restore points")
    func restoreDropsItsRestorePoint() async {
        let (store, a, _) = await twoAppStore()

        for _ in 0..<4 {
            store.removeMyApp(a)
            #expect(store.restoreDeletedMyApp(a))
        }

        let reasons = SnapshotStore.metas(a).map(\.reason)
        #expect(!reasons.contains(.deleted), "restore consumed them: \(reasons)")
    }

    /// Dropping the `.deleted` bases must not dangle the chain of anything that
    /// diffed off one — the `.restored` record written by the cycle before.
    @Test("history still resolves after its .deleted records are dropped")
    func historyResolvesAfterDroppingRestorePoints() async {
        let (store, a, _) = await twoAppStore()
        for i in 0..<3 {
            store.removeMyApp(a)
            #expect(store.restoreDeletedMyApp(a))
            store.renameMyApp(a, to: "Cycle \(i)")
        }

        let metas = SnapshotStore.metas(a)
        #expect(!metas.isEmpty)
        for m in metas {
            #expect(SnapshotStore.restoredApp(a, id: m.id) != nil,
                    "\(m.reason) snapshot no longer resolves")
        }
    }

    /// The drop is scoped: a user pin taken before the delete is permanent and
    /// must survive a restore untouched.
    @Test("restoring keeps the user's pins")
    func restoreKeepsPins() async {
        let (store, a, _) = await twoAppStore()
        guard let app = store.myApp(withId: a) else { Issue.record("missing app"); return }
        SnapshotStore.record(app, reason: .pinned, label: "keep")
        store.removeMyApp(a)
        #expect(store.restoreDeletedMyApp(a))

        let pins = SnapshotStore.metas(a).filter { $0.reason == .pinned }
        #expect(pins.map(\.label) == ["keep"])
        #expect(SnapshotStore.restoredApp(a, id: pins[0].id) != nil)
    }

    /// `restoreDeletedMyApp` is not the only un-delete. Clearing a tombstone
    /// retires the one thing that can ever collect that app's `.deleted`
    /// record, so every path must drop it in the same breath.
    @Test("reviving a deleted app from a pin drops its stranded restore point")
    func revivingFromPinDropsRestorePoint() async {
        let (store, a, _) = await twoAppStore()
        guard let app = store.myApp(withId: a) else { Issue.record("missing app"); return }
        guard let pin = SnapshotStore.record(app, reason: .pinned, label: "keep") else {
            Issue.record("no pin"); return
        }
        store.removeMyApp(a)
        #expect(SnapshotStore.metas(a).contains { $0.reason == .deleted })

        #expect(store.restorePinnedSnapshot(appId: a, snapshotId: pin) == a)

        let reasons = SnapshotStore.metas(a).map(\.reason)
        #expect(!reasons.contains(.deleted), "the tombstone is gone — nothing can collect it: \(reasons)")
        #expect(reasons.contains(.pinned), "the drop is scoped to .deleted")
        for m in SnapshotStore.metas(a) {
            #expect(SnapshotStore.restoredApp(a, id: m.id) != nil, "\(m.reason) no longer resolves")
        }
    }

    @Test("restoring a sync-removed app drops its stranded restore point")
    func syncRemovalRestoreDropsRestorePoint() async {
        let (store, a, _) = await twoAppStore()
        // Another device deletes it; this one only receives the tombstone.
        let other = MyAppStore()
        other.removeMyApp(a)
        await store.reloadFromDisk()
        #expect(store.pendingSyncRemoval?.ids == [a])
        #expect(SnapshotStore.metas(a).contains { $0.reason == .deleted })

        store.restoreSyncRemovedApps()

        #expect(store.myApps.contains { $0.id == a })
        let reasons = SnapshotStore.metas(a).map(\.reason)
        #expect(!reasons.contains(.deleted), "\(reasons)")
        for m in SnapshotStore.metas(a) {
            #expect(SnapshotStore.restoredApp(a, id: m.id) != nil, "\(m.reason) no longer resolves")
        }
    }

    @Test("re-importing a deleted id drops its stranded restore point")
    func importDropsRestorePoint() async {
        let (store, a, _) = await twoAppStore()
        guard let app = store.myApp(withId: a) else { Issue.record("missing app"); return }
        store.removeMyApp(a)
        #expect(SnapshotStore.metas(a).contains { $0.reason == .deleted })

        store.importMyApp(app)

        #expect(!SnapshotStore.metas(a).map(\.reason).contains(.deleted))
    }

    @Test("hasRestoreSource agrees with a real restore for both sources")
    func restoreSourceProbeMatchesReality() async {
        let (store, a, b) = await twoAppStore()
        #expect(MyAppStore.hasRestoreSource(UUID()) == false)

        // Snapshot source: the `.deleted` record written on the way out.
        store.removeMyApp(a)
        #expect(MyAppStore.hasRestoreSource(a))

        // Body source: a tombstone from another device, its snapshot unsynced.
        MyAppStore.writeTombstone(b, name: "Flight search")
        SnapshotStore.deleteAll(b)
        #expect(MyAppStore.hasRestoreSource(b), "the on-disk body is a source too")
    }
}
