import Foundation

/// One-shot adoption of pre-0.0.249 memory folders.
///
/// Before #257 a myApp's memories lived under its **name slug**; since then
/// they live under its immutable **id**. Nothing moved the existing trees, so
/// upgrading left every app pointing at an empty seeded scaffold while its real
/// notes, subagents, and skills sat orphaned one folder over.
///
/// Not a shim — nothing consults the slug at read time. This runs at launch,
/// moves the bytes once, and is self-disabling: the source folder is gone
/// afterwards, so every later pass no-ops on the `exists` guard. No flag to
/// persist, and no read path to unpick.
///
/// **Deleting this later:** drop this file, its test file, and the two
/// `MemoryFolderMigration.run` call sites in `AppView`. Safe once every install
/// has launched once on ≥0.0.252 — anything that hasn't will simply keep its
/// slug folder orphaned, exactly as it would have without this.
enum MemoryFolderMigration {

    /// Move each app's slug folder to its id folder. Returns how many apps were
    /// adopted (0 on a settled install). Pass `(id, name)` pairs from the
    /// roster — the roster is the only thing that knows which slugs are claimed,
    /// which is what keeps this from guessing at stray directories.
    @discardableResult
    static func run(apps: [(id: UUID, name: String)]) -> Int {
        let root = PupaStorage.memoriesRoot
        var adopted = 0
        for app in apps where adopt(app, under: root) { adopted += 1 }
        return adopted
    }

    private static func adopt(_ app: (id: UUID, name: String), under root: URL) -> Bool {
        let slug = MemoryStore.slugify(app.name)
        let idFolder = MemoryStore.myAppFolder(myAppId: app.id)
        // `orchestrator` is a real scope, not an app slug — an app named
        // "Orchestrator" slugifies onto it and would swallow its memories.
        // A slug that is already a uuid can only be an id folder.
        guard !slug.isEmpty, slug != idFolder,
              slug != MemoryStore.orchestratorFolder(),
              UUID(uuidString: slug) == nil else { return false }

        let fm = FileManager.default
        let src = root.appendingPathComponent(slug, isDirectory: true)
        let dst = root.appendingPathComponent(idFolder, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue
        else { return false }

        if !fm.fileExists(atPath: dst.path) {
            guard (try? fm.moveItem(at: src, to: dst)) != nil else { return false }
            return true
        }

        // The id folder already holds a re-seeded scaffold, and possibly notes
        // written since the upgrade. Those are newer, so they win: adopt only
        // the paths it lacks, then drop what's left of the slug tree.
        guard let walker = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey])
        else { return false }
        let srcPrefix = src.standardizedFileURL.path
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false
            else { continue }
            let rel = String(file.standardizedFileURL.path.dropFirst(srcPrefix.count)
                .drop { $0 == "/" })
            let target = dst.appendingPathComponent(rel)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.moveItem(at: file, to: target)
        }
        try? fm.removeItem(at: src)
        return true
    }
}
