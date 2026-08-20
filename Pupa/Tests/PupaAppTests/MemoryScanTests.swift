import Foundation
import Testing
@testable import PupaApp

/// `MemoryStore.scan` is on the MyApp-switch path (the Agents pane builds two
/// stores), so it gets rewritten for syscall count. These pin the tree it
/// produces so the rewrite can't quietly change what the UI shows.
@MainActor
@Suite("Memory scan")
struct MemoryScanTests {

    init() { TestStorage.activate() }

    /// Nested dirs, hidden entries, an empty folder, mixed-case names.
    private func fixture() -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("memscan-\(UUID().uuidString)", isDirectory: true)
        func dir(_ p: String) {
            try? fm.createDirectory(at: root.appendingPathComponent(p, isDirectory: true),
                                    withIntermediateDirectories: true)
        }
        func file(_ p: String, _ bytes: Int) {
            let url = root.appendingPathComponent(p)
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? Data(repeating: 0x61, count: bytes).write(to: url)
        }
        dir("empty")
        dir(".hiddendir")
        file(".hidden", 5)
        file("alpha.md", 10)
        file("Beta.md", 20)
        file("nested/inner.md", 30)
        file("nested/deep/leaf.md", 40)
        return root
    }

    @Test("tree shape, ordering, sizes and hidden-entry skipping")
    func treeIsStable() {
        let tree = MemoryStore(rootOverride: fixture()).tree

        // Folders first, then files; both case-insensitively alphabetised.
        #expect(tree.children?.map(\.name) == ["empty", "nested", "alpha.md", "Beta.md"])

        let byName = Dictionary(uniqueKeysWithValues: (tree.children ?? []).map { ($0.name, $0) })
        #expect(byName["alpha.md"]?.kind == .file(sizeBytes: 10))
        #expect(byName["Beta.md"]?.kind == .file(sizeBytes: 20))
        #expect(byName["empty"]?.kind == .folder)
        #expect(byName["empty"]?.children == [])

        let nested = byName["nested"]
        #expect(nested?.children?.map(\.name) == ["deep", "inner.md"])
        #expect(nested?.children?.last?.kind == .file(sizeBytes: 30))
        #expect(nested?.path == "nested")

        let leaf = nested?.children?.first?.children?.first
        #expect(leaf?.name == "leaf.md")
        #expect(leaf?.path == "nested/deep/leaf.md")
        #expect(leaf?.kind == .file(sizeBytes: 40))
    }

    @Test("scanning costs one directory listing, not three syscalls per entry")
    func scanDoesNotStatPerEntry() {
        let root = fixture()

        DiskIO.reset()
        _ = MemoryStore(rootOverride: root)

        // 7 visible entries across 4 directories. The old scan issued a
        // `fileExists` per entry plus an `attributesOfItem` per file (11);
        // prefetched resource values make that one listing per directory.
        #expect(DiskIO.scans == 1)
        #expect(DiskIO.statCalls == 0, "issued \(DiskIO.statCalls) per-entry stat calls")
    }
}
