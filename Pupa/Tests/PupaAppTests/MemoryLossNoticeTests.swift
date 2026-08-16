import Foundation
import Testing
@testable import PupaApp

/// Follow-up to #251: that fix recovers memory files only on an **un-delete**.
/// A sync that drops an app's `pupa/` config while the app itself stays in the
/// roster quarantines the bytes just the same, and nothing offered them back —
/// the agent roster reads empty with no way to notice or repair it.
///
/// These cover the notice: a lost skill / subagent unit raises it, an ordinary
/// cross-device delete of a single file does not, and recovering re-materializes
/// the files.
@MainActor
@Suite("Memory loss notice", .serialized)
struct MemoryLossNoticeTests {
    init() { TestStorage.activate() }

    /// Quarantine `rel` the way a sync-driven `.deleteLocal` does.
    private func quarantine(_ rel: String, _ body: String, at when: Date = Date()) {
        let dir = PupaStorage.activeRoot
            .appendingPathComponent("conflicts", isDirectory: true)
            .appendingPathComponent(rel, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("2026-01-01T00-00-00Z-abcd.md")
        try? Data(body.utf8).write(to: url)
        try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
    }

    private func memoryBody(_ rel: String) -> String? {
        let url = PupaStorage.memoriesRoot.appendingPathComponent(rel)
        return (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Memory folder = the app's immutable id (lowercased uuid).
    private func folder(_ id: UUID) -> String { MemoryStore.myAppFolder(myAppId: id) }

    /// A live app whose `pupa/skills/warmup/` was taken by a sync: the folder's
    /// only file is in quarantine and nothing is left on disk under it.
    private func storeWithLostSkill() async -> (MyAppStore, String) {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Fitness", iconSystemName: "star")
        let s = folder(id)
        quarantine("memories/\(s)/pupa/skills/warmup/SKILL.md", "warmup skill")
        return (store, s)
    }

    @Test("a skill folder a sync emptied raises the notice")
    func lostSkillRaisesNotice() async throws {
        let (store, _) = await storeWithLostSkill()

        await store.reloadFromDisk()

        let notice = try #require(store.pendingMemoryLoss)
        #expect(notice.names == ["Fitness"])
        #expect(notice.fileCount == 1)
    }

    @Test("recovering re-materializes the files and clears the notice")
    func recoverRestoresFiles() async throws {
        let (store, s) = await storeWithLostSkill()
        await store.reloadFromDisk()

        store.recoverLostMemoryFiles()

        #expect(memoryBody("\(s)/pupa/skills/warmup/SKILL.md") == "warmup skill")
        #expect(store.pendingMemoryLoss == nil)
    }

    /// The nag guard. A file deleted deliberately on another device reaches us
    /// as the same `.deleteLocal`, so the notice can't fire on any single
    /// missing file — only on a whole skill / subagent unit going at once.
    @Test("an ordinary cross-device delete inside a live folder stays silent")
    func partialDeleteIsSilent() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Fitness", iconSystemName: "star")
        let s = folder(id)
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: id))
        _ = try? memory.writeFile(path: "pupa/skills/warmup/SKILL.md", content: "live")
        // A second file in the same unit went; the unit itself is still there.
        quarantine("memories/\(s)/pupa/skills/warmup/NOTES.md", "deleted elsewhere")

        await store.reloadFromDisk()

        #expect(store.pendingMemoryLoss == nil)
    }

    @Test("a unit still on disk is not reported lost")
    func liveUnitIsNotLost() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Fitness", iconSystemName: "star")
        let s = folder(id)
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: id))
        _ = try? memory.writeFile(path: "pupa/skills/warmup/SKILL.md", content: "live")
        quarantine("memories/\(s)/pupa/skills/warmup/SKILL.md", "older losing copy")

        await store.reloadFromDisk()

        #expect(store.pendingMemoryLoss == nil)
    }

    /// Dismissing has to stick, or every relaunch re-raises the same loss.
    @Test("dismissing keeps the notice from coming back")
    func dismissIsDurable() async throws {
        let (store, _) = await storeWithLostSkill()
        await store.reloadFromDisk()
        #expect(store.pendingMemoryLoss != nil)

        store.dismissMemoryLoss()
        await store.reloadFromDisk()

        #expect(store.pendingMemoryLoss == nil)
    }

    /// A *later* loss must still raise after an earlier one was dismissed —
    /// the watermark bounds what has been seen, it doesn't mute the feature.
    @Test("a loss after a dismissal raises again")
    func laterLossRaisesAgain() async throws {
        let (store, s) = await storeWithLostSkill()
        await store.reloadFromDisk()
        store.dismissMemoryLoss()

        quarantine("memories/\(s)/pupa/agents/coach/AGENTS.md", "coach prompt",
                   at: Date(timeIntervalSinceNow: 60))
        await store.reloadFromDisk()

        let notice = try #require(store.pendingMemoryLoss)
        #expect(notice.fileCount == 1)
    }

    @Test("another app's quarantine is not attributed to this one")
    func noticeIsScopedPerApp() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        _ = store.addMyApp(typeId: "tracker", name: "Fitness", iconSystemName: "star")
        // Some other app's folder (a different id) — never attributed here.
        quarantine("memories/\(folder(UUID()))/pupa/skills/x/SKILL.md", "not mine")

        await store.reloadFromDisk()

        #expect(store.pendingMemoryLoss == nil)
    }
}
