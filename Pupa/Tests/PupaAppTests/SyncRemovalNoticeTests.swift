import Foundation
import Testing
@testable import PupaApp

/// Defect C: when an incoming sync removes MiniApps this user did NOT delete, the
/// store applies the merge (data is preserved) and raises a dismissible restore
/// notice. A deliberate local delete raises nothing.
@MainActor
@Suite("Sync-removal advisement", .serialized)
struct SyncRemovalNoticeTests {
    init() { TestStorage.activate() }

    @Test("a remote reload dropping an app raises the notice and restores it")
    func remoteDropRaisesNoticeAndRestores() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()                                   // iCloud off → seeds 1
        let x = a.addMiniApp(typeId: "tracker", name: "Gone", iconSystemName: "star")
        #expect(a.miniApps.contains { $0.id == x })

        // Another device (same on-disk root) deletes it, shrinking the index.
        let b = MiniAppStore()
        b.removeMiniApp(x)
        #expect(!b.miniApps.contains { $0.id == x })

        await a.reloadFromDisk()
        #expect(!a.miniApps.contains { $0.id == x })             // roster shrank
        #expect(a.pendingSyncRemoval?.ids == [x])              // …and a is advised
        #expect(a.pendingSyncRemoval?.names == ["Gone"])

        a.restoreSyncRemovedApps()
        #expect(a.miniApps.contains { $0.id == x })              // restored from snapshot
        #expect(a.pendingSyncRemoval == nil)
    }

    @Test("dismiss clears the notice without restoring")
    func dismissClearsNotice() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        let x = a.addMiniApp(typeId: "tracker", name: "Bye", iconSystemName: "star")
        let b = MiniAppStore()
        b.removeMiniApp(x)

        await a.reloadFromDisk()
        #expect(a.pendingSyncRemoval != nil)
        a.dismissSyncRemoval()
        #expect(a.pendingSyncRemoval == nil)
        #expect(!a.miniApps.contains { $0.id == x })             // not restored
    }

    @Test("a dismissed remote delete still lists under Recently deleted")
    func dismissedRemoteDeleteIsListed() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        let x = a.addMiniApp(typeId: "tracker", name: "Bye", iconSystemName: "star")
        let b = MiniAppStore()
        b.removeMiniApp(x)                                        // writes a tombstone

        await a.reloadFromDisk()
        a.dismissSyncRemoval()

        let listed = MiniAppStore.deletedMiniApps().first { $0.id == x }
        #expect(listed != nil)
        #expect(listed?.wasSyncRemoved == false, "a real delete, made elsewhere")
    }

    /// A bad merge drops an app from the index AND disk with no tombstone —
    /// nothing durable marks it, so before the lost marker a dismissed banner
    /// left it unreachable from the UI. Simulated by deleting on a second store
    /// and then retiring every marker it wrote.
    private func loseWithoutTombstone(_ store: MiniAppStore, _ id: UUID) {
        let other = MiniAppStore()
        other.removeMiniApp(id)
        MiniAppStore.clearDeleteMarkers(id)
    }

    @Test("a dismissed tombstone-less sync removal lands in Recently deleted")
    func dismissedTombstonelessRemovalIsListed() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        let x = a.addMiniApp(typeId: "tracker", name: "Vanished", iconSystemName: "star")
        loseWithoutTombstone(a, x)

        await a.reloadFromDisk()
        #expect(a.pendingSyncRemoval?.ids == [x])
        a.dismissSyncRemoval()

        #expect(!a.miniApps.contains { $0.id == x })
        let listed = MiniAppStore.deletedMiniApps().first { $0.id == x }
        #expect(listed?.name == "Vanished")
        #expect(listed?.isRestorable == true)
        #expect(listed?.wasSyncRemoved == true)
    }

    @Test("Recently deleted restores a sync-lost app")
    func syncLostAppRestoresFromTheList() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        let x = a.addMiniApp(typeId: "tracker", name: "Vanished", iconSystemName: "star")
        loseWithoutTombstone(a, x)
        await a.reloadFromDisk()
        a.dismissSyncRemoval()

        #expect(a.restoreDeletedMiniApp(x))
        #expect(a.miniApps.contains { $0.id == x })
        #expect(!MiniAppStore.deletedMiniApps().contains { $0.id == x }, "the marker is retired")
    }

    /// The marker is local-only by design: the removal may be a bad merge, and
    /// a device that still holds the body must stay free to push it back.
    @Test("a sync-lost app writes no mirrored tombstone")
    func syncLossIsNotMirrored() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        let x = a.addMiniApp(typeId: "tracker", name: "Vanished", iconSystemName: "star")
        loseWithoutTombstone(a, x)
        await a.reloadFromDisk()

        let tombstone = PupaStorage.stateRoot
            .appendingPathComponent("tombstones/\(x.uuidString).json")
        #expect(!FileManager.default.fileExists(atPath: tombstone.path))
        #expect(!PupaStorage.mirroredSubtrees.contains {
            MiniAppStore.lostDir.path.hasPrefix(PupaStorage.activeRoot.appendingPathComponent($0).path)
        }, "the lost marker must live outside every mirrored subtree")
    }

    @Test("ignoring the banner still leaves the app in Recently deleted")
    func ignoredNoticeSurvivesRelaunch() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        let x = a.addMiniApp(typeId: "tracker", name: "Vanished", iconSystemName: "star")
        loseWithoutTombstone(a, x)
        await a.reloadFromDisk()                                 // banner up, never answered

        let relaunched = MiniAppStore()                            // in-memory notice is gone
        #expect(relaunched.pendingSyncRemoval == nil)
        #expect(MiniAppStore.deletedMiniApps().contains { $0.id == x })
        #expect(relaunched.restoreDeletedMiniApp(x))
    }

    @Test("a body that comes back retires the lost marker")
    func returningBodyRetiresTheMarker() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        let x = a.addMiniApp(typeId: "tracker", name: "Vanished", iconSystemName: "star")
        guard let body = a.miniApp(withId: x) else { Issue.record("missing app"); return }
        loseWithoutTombstone(a, x)
        await a.reloadFromDisk()
        #expect(MiniAppStore.deletedMiniApps().contains { $0.id == x })

        // The device that still had it pushes the body back up.
        let other = MiniAppStore()
        other.importMiniApp(body)
        await a.reloadFromDisk()

        #expect(a.miniApps.contains { $0.id == x })
        #expect(!MiniAppStore.deletedMiniApps().contains { $0.id == x },
                "listed as removed while it's live in the roster")
    }

    @Test("a user-initiated delete on THIS device raises no notice")
    func userDeleteRaisesNoNotice() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        let x = a.addMiniApp(typeId: "tracker", name: "Self", iconSystemName: "star")
        a.removeMiniApp(x)                                        // deliberate local delete
        await a.reloadFromDisk()
        #expect(a.pendingSyncRemoval == nil)
    }
}
