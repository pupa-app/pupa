import Foundation
import Testing
@testable import PupaApp

/// 0.0.249 re-keyed a myApp's memory folder from its name slug to its
/// immutable id (#257) without moving what was already on disk, so every
/// pre-upgrade app came back to an empty seeded scaffold. These pin the
/// one-shot adoption that moves the slug folder into place.
///
/// Deletable once every install has launched once — see
/// `MemoryFolderMigration`.
@MainActor
@Suite("Memory folder slug → id migration", .serialized)
struct MemoryFolderMigrationTests {

    init() { TestStorage.activate() }

    private var root: URL { PupaStorage.memoriesRoot }

    private func write(_ relPath: String, _ content: String) throws {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relPath: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(relPath), encoding: .utf8)
    }

    private func exists(_ relPath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relPath).path)
    }

    @Test("a slug folder is adopted into the app's id folder")
    func adoptsSlugFolder() async throws {
        await MyAppStore.clearStorage()
        let id = UUID()
        try write("content-studio/notes/reels.md", "RECIPE")
        try write("content-studio/pupa/agents/editor/AGENTS.md", "editor")

        let moved = MemoryFolderMigration.run(apps: [(id: id, name: "Content Studio")])

        #expect(moved == 1)
        let dst = id.uuidString.lowercased()
        #expect(read("\(dst)/notes/reels.md") == "RECIPE")
        #expect(read("\(dst)/pupa/agents/editor/AGENTS.md") == "editor")
        #expect(!exists("content-studio"))
    }

    @Test("an id folder that already exists absorbs only the files it lacks")
    func mergesWithoutClobbering() async throws {
        await MyAppStore.clearStorage()
        let id = UUID()
        let dst = id.uuidString.lowercased()
        // Post-upgrade state: re-seeded scaffold + a note written since.
        try write("\(dst)/pupa/AGENTS.md", "reseeded")
        try write("\(dst)/test/random.md", "written after the upgrade")
        // Pre-upgrade content stranded under the slug.
        try write("myfire/pupa/AGENTS.md", "the original, hand-edited")
        try write("myfire/pupa/skills/setup/SKILL.md", "setup")

        let moved = MemoryFolderMigration.run(apps: [(id: id, name: "MyFIRE")])

        #expect(moved == 1)
        // Newer file wins — the migration never overwrites what's already there.
        #expect(read("\(dst)/pupa/AGENTS.md") == "reseeded")
        #expect(read("\(dst)/test/random.md") == "written after the upgrade")
        // ...but anything the id folder lacked is adopted.
        #expect(read("\(dst)/pupa/skills/setup/SKILL.md") == "setup")
        #expect(!exists("myfire"))
    }

    @Test("running twice is a no-op — the second pass finds nothing to move")
    func idempotent() async throws {
        await MyAppStore.clearStorage()
        let id = UUID()
        try write("job-search/notes/leads.md", "leads")
        let apps = [(id: id, name: "Job Search")]

        #expect(MemoryFolderMigration.run(apps: apps) == 1)
        #expect(MemoryFolderMigration.run(apps: apps) == 0)
        #expect(read("\(id.uuidString.lowercased())/notes/leads.md") == "leads")
    }

    @Test("an app named Orchestrator never swallows the orchestrator's own folder")
    func refusesOrchestratorFolder() async throws {
        await MyAppStore.clearStorage()
        let id = UUID()
        try write("orchestrator/journal.md", "the orchestrator's own notes")

        #expect(MemoryFolderMigration.run(apps: [(id: id, name: "Orchestrator")]) == 0)
        #expect(read("orchestrator/journal.md") == "the orchestrator's own notes")
        #expect(!exists(id.uuidString.lowercased()))
    }

    @Test("an app with no slug folder on disk is left alone")
    func noSlugFolderIsNoop() async throws {
        await MyAppStore.clearStorage()
        #expect(MemoryFolderMigration.run(apps: [(id: UUID(), name: "Brand New App")]) == 0)
    }

    @Test("two apps sharing a name — the first claims the folder, the second is untouched")
    func duplicateNamesDoNotDoubleClaim() async throws {
        await MyAppStore.clearStorage()
        let first = UUID(), second = UUID()
        try write("daily-briefing/notes/a.md", "a")

        let moved = MemoryFolderMigration.run(apps: [
            (id: first, name: "Daily Briefing"),
            (id: second, name: "Daily Briefing"),
        ])

        #expect(moved == 1)
        #expect(read("\(first.uuidString.lowercased())/notes/a.md") == "a")
        #expect(!exists(second.uuidString.lowercased()))
    }
}
