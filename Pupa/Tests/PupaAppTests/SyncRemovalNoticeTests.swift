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
