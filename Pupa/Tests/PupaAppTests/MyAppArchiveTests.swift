import Foundation
import Testing
@testable import PupaApp

/// Archiving a MyApp hides it from `visibleMyApps` (the sidebar + every
/// agent-facing list), locks its components, repoints the active app, and
/// round-trips through the `MyApp` Codable layer.
@MainActor
@Suite("MyApp archive")
struct MyAppArchiveTests {

    init() { TestStorage.activate() }

    private func twoAppStore() -> (MyAppStore, UUID, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let b = MyApp(name: "B", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a, b], a.id))
        store.setTracker(title: "T", fields: [FieldDef(name: "title", type: .text)], myAppId: a.id)
        return (store, a.id, b.id)
    }

    @Test("archive hides from visibleMyApps, keeps it in myApps, locks components")
    func archiveHidesAndLocks() {
        let (store, a, b) = twoAppStore()
        #expect(store.areAllComponentsLocked(myAppId: a) == false)

        store.setMyAppArchived(a, true)

        #expect(store.visibleMyApps.map(\.id) == [b])          // gone from sidebar list
        #expect(store.myApps.count == 2)                        // still on disk
        #expect(store.archivedMyApps.map(\.id) == [a])
        #expect(store.areAllComponentsLocked(myAppId: a))       // read-only
    }

    @Test("archiving the active app repoints activeMyAppId to a visible one")
    func archiveRepointsActive() {
        let (store, a, b) = twoAppStore()
        #expect(store.activeMyAppId == a)
        store.setMyAppArchived(a, true)
        #expect(store.activeMyAppId == b)
    }

    @Test("unarchive restores to visibleMyApps but keeps the lock on")
    func unarchiveRestoresLocked() {
        let (store, a, _) = twoAppStore()
        store.setMyAppArchived(a, true)
        store.setMyAppArchived(a, false)

        #expect(store.visibleMyApps.contains { $0.id == a })
        #expect(store.archivedMyApps.isEmpty)
        #expect(store.areAllComponentsLocked(myAppId: a))       // lock persists per spec
    }

    @Test("isArchived round-trips through the MyApp Codable layer; legacy blobs default false")
    func codableRoundTrip() throws {
        var app = MyApp(name: "X", iconSystemName: "list", typeId: MyAppType.tracker.id)
        app.isArchived = true
        let data = try JSONEncoder().encode(app)
        #expect(try JSONDecoder().decode(MyApp.self, from: data).isArchived == true)

        // A blob written before the flag existed decodes as not-archived.
        let notArchived = MyApp(name: "Y", iconSystemName: "list", typeId: MyAppType.tracker.id)
        let plain = try JSONEncoder().encode(notArchived)          // encodes no isArchived key
        #expect(try JSONDecoder().decode(MyApp.self, from: plain).isArchived == false)
    }
}
