import Foundation
import Testing
@testable import PupaApp
@testable import AGUIKit

/// Memory lock: a locked MyApp's memory subtree refuses every mutating memory
/// op (with a clear "locked" result to the agent) while reads still work.
@MainActor
@Suite("Memory lock")
struct MemoryLockTests {

    init() { TestStorage.activate() }

    private func freshStore() -> (MyAppStore, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let app = MyApp(name: "Notes App", iconSystemName: "brain", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([app], app.id))
        return (store, app.id)
    }

    /// A temp-rooted scoped store wired to the app's lock exactly as the agent's
    /// per-session store is in `ChatSessionCoordinator`.
    private func tempScoped(guardedBy store: MyAppStore, id: UUID) -> MemoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-memlock-\(UUID().uuidString)", isDirectory: true)
        let mem = MemoryStore(rootOverride: dir)
        mem.writeGuard = { [weak store] _ in store?.isMemoryLocked(myAppId: id) ?? false }
        return mem
    }

    // MARK: - Store state

    @Test("setMemoryLocked toggles state and is idempotent")
    func toggle() {
        let (store, id) = freshStore()
        #expect(!store.isMemoryLocked(myAppId: id))
        #expect(store.setMemoryLocked(true, myAppId: id))
        #expect(store.isMemoryLocked(myAppId: id))
        #expect(!store.setMemoryLocked(true, myAppId: id))   // no-op
        #expect(store.setMemoryLocked(false, myAppId: id))
        #expect(!store.isMemoryLocked(myAppId: id))
    }

    // MARK: - Store-level backstop

    @Test("locked scoped store refuses every mutation; reads still work; unlock restores")
    func backstopBlocksAndRestores() throws {
        let (store, id) = freshStore()
        let mem = tempScoped(guardedBy: store, id: id)
        try mem.writeFile(path: "notes/a.md", content: "hi")   // unlocked: ok

        store.setMemoryLocked(true, myAppId: id)
        #expect(throws: MemoryError.self) { try mem.writeFile(path: "notes/b.md", content: "x") }
        #expect(throws: MemoryError.self) { try mem.appendFile(path: "notes/a.md", content: "x") }
        #expect(throws: MemoryError.self) {
            try mem.editFile(path: "notes/a.md", oldString: "hi", newString: "yo")
        }
        #expect(throws: MemoryError.self) { try mem.createFolder(path: "sub") }
        #expect(throws: MemoryError.self) { try mem.delete(path: "notes/a.md") }
        #expect(throws: MemoryError.self) { try mem.move(from: "notes/a.md", to: "notes/c.md") }

        // Reads are unaffected — nothing was mutated.
        #expect(try mem.readFile(path: "notes/a.md").content == "hi")
        #expect(!mem.fileExists(at: "notes/b.md"))

        store.setMemoryLocked(false, myAppId: id)
        try mem.writeFile(path: "notes/b.md", content: "x")     // restored
        #expect(mem.fileExists(at: "notes/b.md"))
    }

    // MARK: - Global (sidebar) store path guard

    @Test("global-root path guard resolves the leading app folder")
    func rootPathGuard() {
        let (store, id) = freshStore()
        let folder = MemoryStore.myAppFolder(myAppId: id)
        #expect(!store.isMemoryLocked(forRootPath: "\(folder)/notes/a.md"))
        store.setMemoryLocked(true, myAppId: id)
        #expect(store.isMemoryLocked(forRootPath: "\(folder)/notes/a.md"))
        #expect(!store.isMemoryLocked(forRootPath: "\(UUID().uuidString.lowercased())/notes/a.md"))
        #expect(!store.isMemoryLocked(forRootPath: ""))
    }

    // MARK: - Tool layer (agent-facing)

    @Test("mutating memory tool on a locked app returns a locked error; reads still work")
    func toolGating() async throws {
        let (store, id) = freshStore()
        let mem = tempScoped(guardedBy: store, id: id)
        try mem.writeFile(path: "notes/a.md", content: "hi")   // seed before lock
        let registry = ToolRegistry()
        AppTools.registerMemoryTools(on: registry, memory: mem)
        store.setMemoryLocked(true, myAppId: id)

        let write = registry.resolve("writeMemoryFile")!
        let result = try await write.handler(
            .object(["path": .string("notes/b.md"), "content": .string("x")])
        )
        #expect(result["ok"]?.boolValue == false)
        #expect(!mem.fileExists(at: "notes/b.md"))

        // Read-only tool is exempt.
        let read = registry.resolve("readMemoryFile")!
        let readResult = try await read.handler(.object(["path": .string("notes/a.md")]))
        #expect(readResult["ok"]?.boolValue == true)
        #expect(readResult["content"]?.stringValue == "hi")
    }

    // MARK: - Compatibility

    @Test("isMemoryLocked round-trips and is omitted when false (legacy data)")
    func codable() throws {
        var app = MyApp(name: "A", iconSystemName: "brain", typeId: MyAppType.tracker.id)
        let encoder = JSONEncoder()

        let data0 = try encoder.encode(app)
        #expect(!(String(data: data0, encoding: .utf8) ?? "").contains("isMemoryLocked"))
        // A payload without the key (old/imported data) decodes as unlocked.
        #expect(try !JSONDecoder().decode(MyApp.self, from: data0).isMemoryLocked)

        app.isMemoryLocked = true
        let data1 = try encoder.encode(app)
        #expect((String(data: data1, encoding: .utf8) ?? "").contains("isMemoryLocked"))
        #expect(try JSONDecoder().decode(MyApp.self, from: data1).isMemoryLocked)
    }
}
