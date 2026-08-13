import Foundation
import Testing
@testable import PupaApp

/// Deleting a MyApp must leave a restore point and a labelled tombstone, so
/// Settings → Recently deleted can list it and bring it back. Before this, a
/// deliberate delete dropped the body file with nothing capturing it — the
/// delete was silent and final on every device.
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
}
