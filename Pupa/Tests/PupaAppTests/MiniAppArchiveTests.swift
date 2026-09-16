import Foundation
import Testing
@testable import PupaApp

/// Archiving a MiniApp hides it from `visibleMiniApps` (the sidebar + every
/// agent-facing list), locks its components, repoints the active app, and
/// round-trips through the `MiniApp` Codable layer.
@MainActor
@Suite("MiniApp archive")
struct MiniAppArchiveTests {

    init() { TestStorage.activate() }

    private func twoAppStore() -> (MiniAppStore, UUID, UUID) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let a = MiniApp(name: "A", iconSystemName: "list.bullet.rectangle", typeId: MiniAppType.tracker.id)
        let b = MiniApp(name: "B", iconSystemName: "list.bullet.rectangle", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([a, b], a.id))
        store.setTracker(title: "T", fields: [FieldDef(name: "title", type: .text)], miniAppId: a.id)
        return (store, a.id, b.id)
    }

    @Test("archive hides from visibleMiniApps, keeps it in miniApps, locks components")
    func archiveHidesAndLocks() {
        let (store, a, b) = twoAppStore()
        #expect(store.areAllComponentsLocked(miniAppId: a) == false)

        store.setMiniAppArchived(a, true)

        #expect(store.visibleMiniApps.map(\.id) == [b])          // gone from sidebar list
        #expect(store.miniApps.count == 2)                        // still on disk
        #expect(store.archivedMiniApps.map(\.id) == [a])
        #expect(store.areAllComponentsLocked(miniAppId: a))       // read-only
    }

    @Test("archiving the active app repoints activeMiniAppId to a visible one")
    func archiveRepointsActive() {
        let (store, a, b) = twoAppStore()
        #expect(store.activeMiniAppId == a)
        store.setMiniAppArchived(a, true)
        #expect(store.activeMiniAppId == b)
    }

    @Test("unarchive restores to visibleMiniApps but keeps the lock on")
    func unarchiveRestoresLocked() {
        let (store, a, _) = twoAppStore()
        store.setMiniAppArchived(a, true)
        store.setMiniAppArchived(a, false)

        #expect(store.visibleMiniApps.contains { $0.id == a })
        #expect(store.archivedMiniApps.isEmpty)
        #expect(store.areAllComponentsLocked(miniAppId: a))       // lock persists per spec
    }

    @Test("isArchived round-trips through the MiniApp Codable layer; legacy blobs default false")
    func codableRoundTrip() throws {
        var app = MiniApp(name: "X", iconSystemName: "list", typeId: MiniAppType.tracker.id)
        app.isArchived = true
        let data = try JSONEncoder().encode(app)
        #expect(try JSONDecoder().decode(MiniApp.self, from: data).isArchived == true)

        // A blob written before the flag existed decodes as not-archived.
        let notArchived = MiniApp(name: "Y", iconSystemName: "list", typeId: MiniAppType.tracker.id)
        let plain = try JSONEncoder().encode(notArchived)          // encodes no isArchived key
        #expect(try JSONDecoder().decode(MiniApp.self, from: plain).isArchived == false)
    }

    // MARK: - Import interplay (archive is load-bearing here)

    private func tempMemory() -> MemoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-archive-tests-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: dir)
    }

    @Test("an app exported while archived imports as visible (non-archived)")
    func archivedExportImportsVisible() throws {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let mem = tempMemory()
        var app = MiniApp(name: "Backup", iconSystemName: "star", typeId: MiniAppType.tracker.id)
        app.isArchived = true                                       // archived at export time
        let store = MiniAppStore(initial: ([], UUID()))

        let bundle = MiniAppExporter.makeBundle(
            app: app,
            options: .init(selectedComponentIds: Set(app.components.map(\.id)),
                           includeRecords: true, includeMemories: true),
            memory: mem)
        let result = try MiniAppImporter.importBundle(try bundle.encoded(), into: store, memory: mem)

        let imported = try #require(store.miniApps.first { $0.id == result.miniAppId })
        #expect(imported.isArchived == false)                       // lands visible
        #expect(store.visibleMiniApps.contains { $0.id == imported.id })
    }

    @Test("importing a name that matches an archived app renames it (no slug clobber)")
    func importCollidesWithArchivedName() throws {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let mem = tempMemory()
        var existing = MiniApp(name: "Garden", iconSystemName: "leaf", typeId: MiniAppType.tracker.id)
        existing.isArchived = true                                  // hidden, but still on disk
        let keep = MiniApp(name: "Keep", iconSystemName: "star", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([existing, keep], keep.id))

        let incoming = MiniApp(name: "Garden", iconSystemName: "leaf", typeId: MiniAppType.tracker.id)
        let bundle = MiniAppExporter.makeBundle(
            app: incoming,
            options: .init(selectedComponentIds: Set(incoming.components.map(\.id)),
                           includeRecords: true, includeMemories: true),
            memory: mem)
        let result = try MiniAppImporter.importBundle(try bundle.encoded(), into: store, memory: mem)

        let imported = try #require(store.miniApps.first { $0.id == result.miniAppId })
        #expect(imported.name != "Garden")                          // renamed off the archived name
        #expect(imported.isArchived == false)
    }
}
