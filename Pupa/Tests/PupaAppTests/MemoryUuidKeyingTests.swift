import Foundation
import Testing
@testable import PupaApp

/// Memory is keyed on the immutable myApp UUID, not the mutable display-name
/// slug. This makes agent-root ≡ app-root by construction: rename never moves a
/// subtree, and a re-import gets a fresh id so it can never collide with or
/// divert the source app's memories. (Fixes the export→reimport→rename
/// stranding.)
@MainActor
@Suite("Memory keyed by myApp UUID")
struct MemoryUuidKeyingTests {
    init() { TestStorage.activate() }

    private func rootedMemory() -> MemoryStore {
        MemoryStore(rootOverride: PupaStorage.memoriesRoot)
    }

    @Test("A myApp's memory folder is its id; the name resolver agrees")
    func folderIsAppId() {
        let store = MyAppStore(initial: ([], UUID()))
        let id = store.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "star")
        let expected = id.uuidString.lowercased()
        #expect(MemoryStore.myAppFolder(myAppId: id) == expected)
        // The legacy name-keyed helper routes to the same id folder.
        #expect(MemoryStore.myAppFolder(myAppName: "Alpha") == expected)
        #expect(MemoryStore.appRoot(myAppName: "Alpha").lastPathComponent == expected)
    }

    @Test("Rename does not move memory; the folder stays the app id")
    func renameKeepsFolder() throws {
        let store = MyAppStore(initial: ([], UUID()))
        let id = store.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "star")
        let mem = rootedMemory()
        try mem.appScopedStore(forAppId: id).writeFile(path: "notes/a.md", content: "hi")

        store.renameMyApp(id, to: "Bravo")

        // File still under the id folder; the new name resolves there; no slug
        // folder was ever created.
        #expect(mem.appScopedStore(forAppId: id).fileExists(at: "notes/a.md"))
        #expect(MemoryStore.myAppFolder(myAppName: "Bravo") == id.uuidString.lowercased())
        #expect(!mem.folderExists(at: "alpha"))
        #expect(!mem.folderExists(at: "bravo"))
    }

    @Test("Re-importing a still-present app gets a fresh id; memories don't collide")
    func reimportFreshIdNoCollision() throws {
        let store = MyAppStore(initial: ([], UUID()))
        let id1 = store.addMyApp(typeId: "tracker", name: "Studio", iconSystemName: "star")
        let mem = rootedMemory()
        try mem.appScopedStore(forAppId: id1).writeFile(path: "notes/keep.md", content: "original")

        let app = try #require(store.myApp(withId: id1))
        let opts = MyAppExporter.Options(
            selectedComponentIds: Set(app.components.map(\.id)),
            includeRecords: true, includeMemories: true)
        let bundle = MyAppExporter.makeBundle(app: app, options: opts, memory: mem)
        let result = try MyAppImporter.importBundle(try bundle.encoded(), into: store, memory: mem)

        // Fresh id — the reimport can't reuse or clobber the source app's folder.
        #expect(result.myAppId != id1)
        #expect(store.myApps.count == 2)
        // Both apps' memories live under their own id folders, both intact.
        #expect(mem.appScopedStore(forAppId: id1).fileExists(at: "notes/keep.md"))
        #expect(mem.appScopedStore(forAppId: result.myAppId).fileExists(at: "notes/keep.md"))
        #expect(MemoryStore.myAppFolder(myAppId: id1)
            != MemoryStore.myAppFolder(myAppId: result.myAppId))
    }
}
