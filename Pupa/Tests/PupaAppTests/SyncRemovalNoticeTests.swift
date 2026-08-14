import Foundation
import Testing
@testable import PupaApp

/// Defect C: when an incoming sync removes MyApps this user did NOT delete, the
/// store applies the merge (data is preserved) and raises a dismissible restore
/// notice. A deliberate local delete raises nothing.
@MainActor
@Suite("Sync-removal advisement", .serialized)
struct SyncRemovalNoticeTests {
    init() { TestStorage.activate() }

    @Test("a remote reload dropping an app raises the notice and restores it")
    func remoteDropRaisesNoticeAndRestores() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()                                   // iCloud off → seeds 1
        let x = a.addMyApp(typeId: "tracker", name: "Gone", iconSystemName: "star")
        #expect(a.myApps.contains { $0.id == x })

        // Another device (same on-disk root) deletes it, shrinking the index.
        let b = MyAppStore()
        b.removeMyApp(x)
        #expect(!b.myApps.contains { $0.id == x })

        await a.reloadFromDisk()
        #expect(!a.myApps.contains { $0.id == x })             // roster shrank
        #expect(a.pendingSyncRemoval?.ids == [x])              // …and a is advised
        #expect(a.pendingSyncRemoval?.names == ["Gone"])

        a.restoreSyncRemovedApps()
        #expect(a.myApps.contains { $0.id == x })              // restored from snapshot
        #expect(a.pendingSyncRemoval == nil)
    }

    @Test("dismiss clears the notice without restoring")
    func dismissClearsNotice() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let x = a.addMyApp(typeId: "tracker", name: "Bye", iconSystemName: "star")
        let b = MyAppStore()
        b.removeMyApp(x)

        await a.reloadFromDisk()
        #expect(a.pendingSyncRemoval != nil)
        a.dismissSyncRemoval()
        #expect(a.pendingSyncRemoval == nil)
        #expect(!a.myApps.contains { $0.id == x })             // not restored
    }

    @Test("a dismissed remote delete still lists under Recently deleted")
    func dismissedRemoteDeleteIsListed() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let x = a.addMyApp(typeId: "tracker", name: "Bye", iconSystemName: "star")
        let b = MyAppStore()
        b.removeMyApp(x)                                        // writes a tombstone

        await a.reloadFromDisk()
        a.dismissSyncRemoval()

        let listed = MyAppStore.deletedMyApps().first { $0.id == x }
        #expect(listed != nil)
        #expect(listed?.wasSyncRemoved == false, "a real delete, made elsewhere")
    }

    /// A bad merge drops an app from the index AND disk with no tombstone —
    /// nothing durable marks it, so before the lost marker a dismissed banner
    /// left it unreachable from the UI. Simulated by deleting on a second store
    /// and then retiring every marker it wrote.
    private func loseWithoutTombstone(_ store: MyAppStore, _ id: UUID) {
        let other = MyAppStore()
        other.removeMyApp(id)
        MyAppStore.clearDeleteMarkers(id)
    }

    @Test("a dismissed tombstone-less sync removal lands in Recently deleted")
    func dismissedTombstonelessRemovalIsListed() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let x = a.addMyApp(typeId: "tracker", name: "Vanished", iconSystemName: "star")
        loseWithoutTombstone(a, x)

        await a.reloadFromDisk()
        #expect(a.pendingSyncRemoval?.ids == [x])
        a.dismissSyncRemoval()

        #expect(!a.myApps.contains { $0.id == x })
        let listed = MyAppStore.deletedMyApps().first { $0.id == x }
        #expect(listed?.name == "Vanished")
        #expect(listed?.isRestorable == true)
        #expect(listed?.wasSyncRemoved == true)
    }

    @Test("Recently deleted restores a sync-lost app")
    func syncLostAppRestoresFromTheList() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let x = a.addMyApp(typeId: "tracker", name: "Vanished", iconSystemName: "star")
        loseWithoutTombstone(a, x)
        await a.reloadFromDisk()
        a.dismissSyncRemoval()

        #expect(a.restoreDeletedMyApp(x))
        #expect(a.myApps.contains { $0.id == x })
        #expect(!MyAppStore.deletedMyApps().contains { $0.id == x }, "the marker is retired")
    }

    /// The marker is local-only by design: the removal may be a bad merge, and
    /// a device that still holds the body must stay free to push it back.
    @Test("a sync-lost app writes no mirrored tombstone")
    func syncLossIsNotMirrored() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let x = a.addMyApp(typeId: "tracker", name: "Vanished", iconSystemName: "star")
        loseWithoutTombstone(a, x)
        await a.reloadFromDisk()

        let tombstone = PupaStorage.stateRoot
            .appendingPathComponent("tombstones/\(x.uuidString).json")
        #expect(!FileManager.default.fileExists(atPath: tombstone.path))
        #expect(!PupaStorage.mirroredSubtrees.contains {
            MyAppStore.lostDir.path.hasPrefix(PupaStorage.activeRoot.appendingPathComponent($0).path)
        }, "the lost marker must live outside every mirrored subtree")
    }

    @Test("ignoring the banner still leaves the app in Recently deleted")
    func ignoredNoticeSurvivesRelaunch() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let x = a.addMyApp(typeId: "tracker", name: "Vanished", iconSystemName: "star")
        loseWithoutTombstone(a, x)
        await a.reloadFromDisk()                                 // banner up, never answered

        let relaunched = MyAppStore()                            // in-memory notice is gone
        #expect(relaunched.pendingSyncRemoval == nil)
        #expect(MyAppStore.deletedMyApps().contains { $0.id == x })
        #expect(relaunched.restoreDeletedMyApp(x))
    }

    @Test("a body that comes back retires the lost marker")
    func returningBodyRetiresTheMarker() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let x = a.addMyApp(typeId: "tracker", name: "Vanished", iconSystemName: "star")
        guard let body = a.myApp(withId: x) else { Issue.record("missing app"); return }
        loseWithoutTombstone(a, x)
        await a.reloadFromDisk()
        #expect(MyAppStore.deletedMyApps().contains { $0.id == x })

        // The device that still had it pushes the body back up.
        let other = MyAppStore()
        other.importMyApp(body)
        await a.reloadFromDisk()

        #expect(a.myApps.contains { $0.id == x })
        #expect(!MyAppStore.deletedMyApps().contains { $0.id == x },
                "listed as removed while it's live in the roster")
    }

    @Test("a user-initiated delete on THIS device raises no notice")
    func userDeleteRaisesNoNotice() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let x = a.addMyApp(typeId: "tracker", name: "Self", iconSystemName: "star")
        a.removeMyApp(x)                                        // deliberate local delete
        await a.reloadFromDisk()
        #expect(a.pendingSyncRemoval == nil)
    }
}
