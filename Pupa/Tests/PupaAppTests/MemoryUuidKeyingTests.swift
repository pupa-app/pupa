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
    /// `registerBuiltins` so the import path resolves `tracker` when this suite
    /// runs on its own (`make test FILTER=…`), not just after another suite.
    init() {
        TestStorage.activate()
        MyAppTypeRegistry.shared.registerBuiltins()
    }

    private func rootedMemory() -> MemoryStore {
        MemoryStore(rootOverride: PupaStorage.memoriesRoot)
    }

    @Test("A myApp's memory folder is its id")
    func folderIsAppId() {
        let store = MyAppStore(initial: ([], UUID()))
        let id = store.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "star")
        let expected = id.uuidString.lowercased()
        #expect(MemoryStore.myAppFolder(myAppId: id) == expected)
        #expect(MemoryStore.appRoot(myAppId: id).lastPathComponent == expected)
    }

    @Test("Rename does not move memory; the folder stays the app id")
    func renameKeepsFolder() throws {
        let store = MyAppStore(initial: ([], UUID()))
        let id = store.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "star")
        let mem = rootedMemory()
        try mem.appScopedStore(forAppId: id).writeFile(path: "notes/a.md", content: "hi")

        store.renameMyApp(id, to: "Bravo")

        // File still under the id folder; no name-slug folder was ever created.
        #expect(mem.appScopedStore(forAppId: id).fileExists(at: "notes/a.md"))
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

    /// The stale-session-root defect: the session used to bake `appRoot(name)`
    /// at creation, so a rename mid-session sent every later write to the old
    /// slug while the UI read the new one.
    @Test("A session created before a rename still writes under the app id")
    func sessionSurvivesMidSessionRename() async throws {
        let store = MyAppStore(initial: ([], UUID()))
        let id = store.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "star")
        let coord = ChatSessionCoordinator(
            store: store,
            memory: rootedMemory(),
            settings: SettingsStore(backendURL: URL(string: "http://localhost:65535/")!))
        let session = coord.session(for: .myApp(id))

        store.renameMyApp(id, to: "Bravo")

        // Write the way the agent does — through the session's own scoped store.
        let write = try #require(session.registry.resolve("writeMemoryFile"))
        _ = try await write.handler(.object([
            "path": .string("notes/after.md"),
            "content": .string("post-rename"),
        ]))

        #expect(rootedMemory().appScopedStore(forAppId: id).fileExists(at: "notes/after.md"))
        #expect(!rootedMemory().folderExists(at: "bravo"))
    }

    /// The supported upgrade path: export on the old build, import into a fresh
    /// store. Memories must land under the new app's id, not any name slug.
    @Test("Export → fresh store → import lands memories under the new id")
    func exportImportIntoFreshStore() throws {
        let source = MyAppStore(initial: ([], UUID()))
        let id = source.addMyApp(typeId: "tracker", name: "Studio", iconSystemName: "star")
        let mem = rootedMemory()
        try mem.appScopedStore(forAppId: id).writeFile(path: "notes/keep.md", content: "carried")

        let app = try #require(source.myApp(withId: id))
        let opts = MyAppExporter.Options(
            selectedComponentIds: Set(app.components.map(\.id)),
            includeRecords: true, includeMemories: true)
        let bundle = try MyAppExporter.makeBundle(app: app, options: opts, memory: mem).encoded()

        // A fresh install: empty store, same name free again.
        let fresh = MyAppStore(initial: ([], UUID()))
        let result = try MyAppImporter.importBundle(bundle, into: fresh, memory: mem)

        let imported = try #require(fresh.myApps.first { $0.id == result.myAppId })
        #expect(imported.name == "Studio")          // no dedup suffix — nothing to clash with
        #expect(mem.appScopedStore(forAppId: result.myAppId).fileExists(at: "notes/keep.md"))
        #expect(mem.folderExists(at: MemoryStore.myAppFolder(myAppId: result.myAppId)))
    }
}
