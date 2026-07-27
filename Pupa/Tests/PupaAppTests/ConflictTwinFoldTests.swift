import Foundation
import Testing
@testable import PupaApp

/// Covers `MemoryStore.foldConflictTwinDirs` — adopting iCloud conflict-renamed
/// twin dirs (`<slug> 2/`, space+digits — never valid slugify output) back into
/// their base slug dir, destination-wins, with differing twin copies preserved
/// under the sibling `conflicts/` tree.
@MainActor
@Suite("Conflict twin fold")
struct ConflictTwinFoldTests {

    init() { TestStorage.activate() }

    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("twin-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func put(_ root: URL, _ rel: String, _ content: String) {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(content.utf8).write(to: url)
    }

    private func get(_ root: URL, _ rel: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(rel)))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    private func exists(_ root: URL, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path)
    }

    /// Store rooted at `<tmp>/memories` so the quarantine lands at
    /// `<tmp>/conflicts/memories/…` (mirrors the real activeRoot layout).
    private func makeStore() -> (store: MemoryStore, parent: URL, memories: URL) {
        let parent = tmp()
        let memories = parent.appendingPathComponent("memories", isDirectory: true)
        return (MemoryStore(rootOverride: memories), parent, memories)
    }

    @Test("fold merges a space-digit twin into its base; destination wins; twin removed")
    func foldMergesTwin() {
        let (store, _, memories) = makeStore()
        put(memories, "jobhunting/pupa/AGENTS.md", "base prompt")
        put(memories, "jobhunting 2/notes/a.md", "twin only")
        put(memories, "jobhunting 2/pupa/AGENTS.md", "base prompt")   // identical → dropped
        let changed = store.foldConflictTwinDirs(addressableBases: ["jobhunting"])
        #expect(changed)
        #expect(get(memories, "jobhunting/notes/a.md") == "twin only")
        #expect(get(memories, "jobhunting/pupa/AGENTS.md") == "base prompt")
        #expect(!exists(memories, "jobhunting 2"))
    }

    @Test("fold preserves a differing twin copy under conflicts/ and is idempotent")
    func foldPreservesDiffering() {
        let (store, parent, memories) = makeStore()
        put(memories, "jobhunting/pupa/AGENTS.md", "keep me")
        put(memories, "jobhunting 2/pupa/AGENTS.md", "twin variant")
        #expect(store.foldConflictTwinDirs(addressableBases: ["jobhunting"]))
        #expect(get(memories, "jobhunting/pupa/AGENTS.md") == "keep me")   // destination wins
        let quarantine = parent.appendingPathComponent(
            "conflicts/memories/jobhunting/pupa/AGENTS.md", isDirectory: true)
        let copies = (try? FileManager.default.contentsOfDirectory(
            at: quarantine, includingPropertiesForKeys: nil)) ?? []
        #expect(copies.count == 1)
        #expect(copies.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "twin variant")
        #expect(!exists(memories, "jobhunting 2"))
        #expect(store.foldConflictTwinDirs(addressableBases: ["jobhunting"]) == false)  // idempotent
    }

    @Test("fold ignores a space-digit dir whose base is not addressable")
    func foldIgnoresUnaddressable() {
        let (store, _, memories) = makeStore()
        put(memories, "scratch 2/x.md", "agent-made dir, leave alone")
        #expect(store.foldConflictTwinDirs(addressableBases: ["jobhunting"]) == false)
        #expect(get(memories, "scratch 2/x.md") == "agent-made dir, leave alone")
    }

    @Test("fold skips a twin whose fake-cloud counterpart holds an .icloud stub")
    func foldSkipsUndownloadedCloudTwin() async throws {
        let cloud = tmp()
        put(cloud, "memories/jobhunting 2/.a.md.icloud", "{}")
        try await TestStorage.withCloudMirror(cloud) {
            let (store, _, memories) = makeStore()
            put(memories, "jobhunting/pupa/AGENTS.md", "base")
            put(memories, "jobhunting 2/b.md", "already local")
            #expect(store.foldConflictTwinDirs(addressableBases: ["jobhunting"]) == false)
            #expect(get(memories, "jobhunting 2/b.md") == "already local")   // untouched this pass
        }
    }

    @Test("orchestrator twin folds")
    func orchestratorTwinFolds() {
        let (store, _, memories) = makeStore()
        put(memories, "orchestrator 2/notes.md", "from twin")
        #expect(store.foldConflictTwinDirs(addressableBases: ["orchestrator"]))
        #expect(get(memories, "orchestrator/notes.md") == "from twin")
        #expect(!exists(memories, "orchestrator 2"))
    }

    @Test("end-to-end: after fold, reconcile pushes adopted files and drops cloud twin files")
    func foldThenConvergePropagates() {
        let (_, parent, memories) = makeStore()
        let cloud = tmp()
        // Device had base + twin fully synced (baseline knows both).
        put(memories, "jobhunting/pupa/AGENTS.md", "prompt")
        put(memories, "jobhunting 2/notes/a.md", "user note")
        StorageMirror.converge(localRoot: parent, cloudRoot: cloud)
        #expect(get(cloud, "memories/jobhunting 2/notes/a.md") == "user note")

        let store = MemoryStore(rootOverride: memories)
        #expect(store.foldConflictTwinDirs(addressableBases: ["jobhunting"]))
        StorageMirror.converge(localRoot: parent, cloudRoot: cloud)
        #expect(get(cloud, "memories/jobhunting/notes/a.md") == "user note")      // adopted rel pushed
        #expect(!exists(cloud, "memories/jobhunting 2/notes/a.md"))               // twin rel deleted
        #expect(get(memories, "jobhunting/notes/a.md") == "user note")
    }
}
