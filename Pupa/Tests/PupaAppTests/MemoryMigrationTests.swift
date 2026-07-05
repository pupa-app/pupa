import Foundation
import Testing
@testable import PupaApp

/// `MemoryStore.migrateAppFolder` — the rename-follows-memories move
/// (issue #112) — plus the scoped-store → parent tree propagation.
@MainActor
@Suite("Memory folder migration on rename")
struct MemoryMigrationTests {

    init() { TestStorage.activate() }

    private func tempMemory() -> MemoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-mig-tests-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: dir)
    }

    @Test("Whole folder moves when the destination slug is free")
    func wholeMove() throws {
        let mem = tempMemory()
        try mem.appScopedStore(forAppNamed: "Alpha").writeFile(path: "notes/a.md", content: "A")

        mem.migrateAppFolder(fromAppNamed: "Alpha", toAppNamed: "Bravo")

        #expect(mem.appScopedStore(forAppNamed: "Bravo").fileExists(at: "notes/a.md"))
        #expect(!mem.folderExists(at: "alpha"))
    }

    @Test("Merge into an existing destination: destination file wins, rest move over")
    func mergeKeepsDestination() throws {
        let mem = tempMemory()
        let src = mem.appScopedStore(forAppNamed: "Alpha")
        try src.writeFile(path: "notes/conflict.md", content: "from alpha")
        try src.writeFile(path: "notes/only-alpha.md", content: "moves")
        try mem.appScopedStore(forAppNamed: "Bravo")
            .writeFile(path: "notes/conflict.md", content: "from bravo")

        mem.migrateAppFolder(fromAppNamed: "Alpha", toAppNamed: "Bravo")

        let dst = mem.appScopedStore(forAppNamed: "Bravo")
        #expect(try dst.readFile(path: "notes/conflict.md").content == "from bravo")
        #expect(dst.fileExists(at: "notes/only-alpha.md"))
        // The conflicted source copy stays put rather than being destroyed.
        #expect(try mem.appScopedStore(forAppNamed: "Alpha")
            .readFile(path: "notes/conflict.md").content == "from alpha")
    }

    @Test("Rename that keeps the same slug is a no-op")
    func sameSlugNoOp() throws {
        let mem = tempMemory()
        try mem.appScopedStore(forAppNamed: "Alpha").writeFile(path: "notes/a.md", content: "A")

        mem.migrateAppFolder(fromAppNamed: "Alpha", toAppNamed: "Alpha!")

        #expect(mem.appScopedStore(forAppNamed: "Alpha").fileExists(at: "notes/a.md"))
    }

    @Test("Missing source folder is a no-op")
    func missingSourceNoOp() {
        let mem = tempMemory()
        mem.migrateAppFolder(fromAppNamed: "Ghost", toAppNamed: "Bravo")
        #expect(!mem.folderExists(at: "bravo"))
    }

    @Test("renameMyApp without a wired globalMemory still renames the app")
    func renameWithoutGlobalMemory() {
        let app = MyApp(name: "Alpha", iconSystemName: "star", typeId: "tracker")
        let store = MyAppStore(initial: ([app], app.id))
        store.renameMyApp(app.id, to: "Bravo")
        #expect(store.myApp(withId: app.id)?.name == "Bravo")
    }

    @Test("Writes through an app-scoped store refresh the parent tree")
    func scopedWriteRefreshesParent() throws {
        let mem = tempMemory()
        try mem.appScopedStore(forAppNamed: "Alpha").writeFile(path: "notes/a.md", content: "A")
        // The parent's *in-memory* tree picked up the child's write.
        let slugNode = mem.tree.children?.first { $0.name == "alpha" }
        #expect(slugNode != nil)
    }
}
