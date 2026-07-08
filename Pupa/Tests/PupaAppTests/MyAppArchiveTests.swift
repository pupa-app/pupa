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

    // MARK: - Import interplay (archive is load-bearing here)

    private func tempMemory() -> MemoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-archive-tests-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: dir)
    }

    @Test("an app exported while archived imports as visible (non-archived)")
    func archivedExportImportsVisible() throws {
        MyAppTypeRegistry.shared.registerBuiltins()
        let mem = tempMemory()
        var app = MyApp(name: "Backup", iconSystemName: "star", typeId: MyAppType.tracker.id)
        app.isArchived = true                                       // archived at export time
        let store = MyAppStore(initial: ([], UUID()))

        let bundle = MyAppExporter.makeBundle(
            app: app,
            options: .init(selectedComponentIds: Set(app.components.map(\.id)),
                           includeRecords: true, includeMemories: true),
            memory: mem)
        let result = try MyAppImporter.importBundle(try bundle.encoded(), into: store, memory: mem)

        let imported = try #require(store.myApps.first { $0.id == result.myAppId })
        #expect(imported.isArchived == false)                       // lands visible
        #expect(store.visibleMyApps.contains { $0.id == imported.id })
    }

    @Test("importing a name that matches an archived app renames it (no slug clobber)")
    func importCollidesWithArchivedName() throws {
        MyAppTypeRegistry.shared.registerBuiltins()
        let mem = tempMemory()
        var existing = MyApp(name: "Garden", iconSystemName: "leaf", typeId: MyAppType.tracker.id)
        existing.isArchived = true                                  // hidden, but still on disk
        let keep = MyApp(name: "Keep", iconSystemName: "star", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([existing, keep], keep.id))

        let incoming = MyApp(name: "Garden", iconSystemName: "leaf", typeId: MyAppType.tracker.id)
        let bundle = MyAppExporter.makeBundle(
            app: incoming,
            options: .init(selectedComponentIds: Set(incoming.components.map(\.id)),
                           includeRecords: true, includeMemories: true),
            memory: mem)
        let result = try MyAppImporter.importBundle(try bundle.encoded(), into: store, memory: mem)

        let imported = try #require(store.myApps.first { $0.id == result.myAppId })
        #expect(imported.name != "Garden")                          // renamed off the archived name
        #expect(imported.isArchived == false)
    }
}
