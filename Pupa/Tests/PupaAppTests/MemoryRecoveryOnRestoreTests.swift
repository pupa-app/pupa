import Foundation
import Testing
@testable import PupaApp

/// Issue #251: an app restored after iCloud removed its data came back with
/// empty `pupa/agents/<slug>/` and `pupa/skills/<name>/` folders — subagents and
/// custom skills silently gone.
///
/// The mirror already quarantines the bytes before unlinking (`apply`'s
/// `.deleteLocal` → `preserveLoser`); nothing ever brought them back. These
/// cover the recovery half: the restore paths re-materialize the app's memory
/// files from quarantine, and only the ones that belong to it.
///
/// Every test uses its own app name: `clearStorage()` wipes `state/` and
/// `lost/`, not `memories/` or `conflicts/`, so shared names would let one
/// test's recovered file satisfy the next test's assertion.
@MainActor
@Suite("Memory recovery on restore", .serialized)
struct MemoryRecoveryOnRestoreTests {
    init() { TestStorage.activate() }

    /// Quarantine `rel` the way `preserveLoser` does — `conflicts/<rel>/<stamp>`
    /// — with an explicit preservation time.
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

    private func slug(_ name: String) -> String { MemoryStore.myAppFolder(myAppName: name) }

    @Test("restoring a deleted app re-materializes its quarantined memory files")
    func restoreRecoversMemoryFiles() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Fitness deleted", iconSystemName: "star")
        let s = slug("Fitness deleted")
        store.removeMyApp(id)
        // iCloud dropped the memory tree; the mirror quarantined it on the way out.
        quarantine("memories/\(s)/pupa/agents/coach/AGENTS.md", "coach prompt")
        quarantine("memories/\(s)/pupa/skills/warmup/SKILL.md", "warmup skill")

        #expect(store.restoreDeletedMyApp(id))

        #expect(memoryBody("\(s)/pupa/agents/coach/AGENTS.md") == "coach prompt")
        #expect(memoryBody("\(s)/pupa/skills/warmup/SKILL.md") == "warmup skill")
    }

    @Test("a sync-lost app recovers its memory files too")
    func syncLostAppRecoversMemoryFiles() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let id = a.addMyApp(typeId: "tracker", name: "Fitness sync lost", iconSystemName: "star")
        let s = slug("Fitness sync lost")
        let other = MyAppStore()
        other.removeMyApp(id)
        MyAppStore.clearDeleteMarkers(id)          // vanished with no tombstone
        await a.reloadFromDisk()
        quarantine("memories/\(s)/pupa/agents/coach/AGENTS.md", "coach prompt")

        a.restoreSyncRemovedApps()

        #expect(a.myApps.contains { $0.id == id })
        #expect(memoryBody("\(s)/pupa/agents/coach/AGENTS.md") == "coach prompt")
    }

    @Test("reviving a deleted app from a pinned snapshot recovers its memory files")
    func pinnedReviveRecoversMemoryFiles() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Fitness pinned", iconSystemName: "star")
        let s = slug("Fitness pinned")
        #expect(store.takeSnapshot(myAppId: id, label: "v1") != nil)
        let pin = try #require(SnapshotStore.pinnedMetas(id).first)
        store.removeMyApp(id)
        quarantine("memories/\(s)/pupa/agents/coach/AGENTS.md", "coach prompt")

        #expect(store.restorePinnedSnapshot(appId: id, snapshotId: pin.id) == id)

        #expect(memoryBody("\(s)/pupa/agents/coach/AGENTS.md") == "coach prompt")
    }

    /// A pin taken before a rename revives the app under its *old* name, but the
    /// quarantined paths carry the name it had when it was removed (a rename
    /// migrates the memory folder). Recovery bridges the two, so the files land
    /// where the revived app actually reads.
    @Test("a pin from before a rename recovers into the revived app's folder")
    func pinnedReviveBridgesARename() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Rename before", iconSystemName: "star")
        #expect(store.takeSnapshot(myAppId: id, label: "v1") != nil)
        let pin = try #require(SnapshotStore.pinnedMetas(id).first)
        store.renameMyApp(id, to: "Rename after")
        store.removeMyApp(id)
        quarantine("memories/\(slug("Rename after"))/pupa/agents/coach/AGENTS.md", "coach prompt")

        #expect(store.restorePinnedSnapshot(appId: id, snapshotId: pin.id) == id)

        #expect(store.myApps.first { $0.id == id }?.name == "Rename before")
        #expect(memoryBody("\(slug("Rename before"))/pupa/agents/coach/AGENTS.md") == "coach prompt")
    }

    @Test("recovery never overwrites a memory file that is still on disk")
    func liveFileWins() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Fitness live wins", iconSystemName: "star")
        let s = slug("Fitness live wins")
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: "Fitness live wins"))
        _ = try? memory.writeFile(path: "pupa/skills/warmup/SKILL.md", content: "live")
        store.removeMyApp(id)
        quarantine("memories/\(s)/pupa/skills/warmup/SKILL.md", "stale quarantined copy")

        #expect(store.restoreDeletedMyApp(id))

        #expect(memoryBody("\(s)/pupa/skills/warmup/SKILL.md") == "live")
    }

    /// The resurrection hazard: a file the user deliberately deleted on another
    /// device is quarantined by the same mechanism. Only what was lost around
    /// the removal comes back.
    @Test("a file quarantined long before the removal is not resurrected")
    func staleQuarantineIsNotResurrected() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Fitness stale", iconSystemName: "star")
        let s = slug("Fitness stale")
        store.removeMyApp(id)
        quarantine("memories/\(s)/pupa/skills/dropped/SKILL.md", "deliberately deleted",
                   at: Date(timeIntervalSinceNow: -3 * 24 * 3600))

        #expect(store.restoreDeletedMyApp(id))

        #expect(memoryBody("\(s)/pupa/skills/dropped/SKILL.md") == nil)
    }

    @Test("recovery is scoped to the restored app's own memory folder")
    func otherAppsMemoryIsUntouched() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Fitness scoped", iconSystemName: "star")
        store.removeMyApp(id)
        quarantine("memories/\(slug("Other app scoped"))/pupa/skills/x/SKILL.md", "not mine")

        #expect(store.restoreDeletedMyApp(id))

        #expect(memoryBody("\(slug("Other app scoped"))/pupa/skills/x/SKILL.md") == nil)
    }
}
