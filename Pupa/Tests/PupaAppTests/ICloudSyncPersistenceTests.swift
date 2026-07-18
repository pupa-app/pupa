import Foundation
import Testing
@testable import PupaApp

/// Covers the iCloud-Documents persistence rework: `CloudDocument` coordinated
/// IO, `MyAppStore`'s per-file `state/` layout, and `MemoryStore` round-trips.
/// All file IO is redirected to a temp dir by `TestStorage`.
@MainActor
@Suite("iCloud sync persistence", .serialized)
struct ICloudSyncPersistenceTests {

    init() { TestStorage.activate() }

    @Test("CloudDocument write → read → move → delete round-trips")
    func cloudDocumentRoundTrip() throws {
        let dir = TestStorage.root.appendingPathComponent("cd-\(UUID().uuidString)", isDirectory: true)
        let a = dir.appendingPathComponent("a.json")
        let b = dir.appendingPathComponent("nested/b.json")
        let payload = Data("hello".utf8)

        try CloudDocument.write(payload, to: a)
        #expect(CloudDocument.read(a) == payload)

        try CloudDocument.move(from: a, to: b)        // creates nested/
        #expect(CloudDocument.read(a) == nil)
        #expect(CloudDocument.read(b) == payload)

        CloudDocument.delete(b)
        #expect(CloudDocument.read(b) == nil)
        CloudDocument.delete(b)                       // idempotent, no throw
    }

    @Test("MyAppStore seeds per-file state and reloads in a fresh instance")
    func myAppStorePerFileRoundTrip() async throws {
        await MyAppStore.clearStorage()
        let writer = MyAppStore()                     // fresh install → seeds + writes
        let newID = writer.addMyApp(typeId: "tracker", name: "Synced", iconSystemName: "star")

        // Per-file layout: one file per app + an index.
        let fm = FileManager.default
        let appsDir = PupaStorage.stateRoot.appendingPathComponent("apps")
        let appFiles = try fm.contentsOfDirectory(atPath: appsDir.path).filter { $0.hasSuffix(".json") }
        #expect(appFiles.count == writer.myApps.count)
        #expect(fm.fileExists(atPath: PupaStorage.stateRoot.appendingPathComponent("index.json").path))

        // A second instance loads the same data from disk.
        let reader = MyAppStore()
        #expect(reader.myApps.contains { $0.id == newID && $0.name == "Synced" })
        #expect(reader.myApps.count == writer.myApps.count)
    }

    @Test("reloadFromDisk (async, off-main) republishes an external write")
    func reloadFromDiskPicksUpExternalChange() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()                          // fresh install → seeds + writes
        let initialCount = a.myApps.count

        // A second store writes a new app to the same on-disk root (stands in
        // for another device's edit landing in the iCloud container).
        let b = MyAppStore()
        let newID = b.addMyApp(typeId: "tracker", name: "Remote", iconSystemName: "star")
        #expect(!a.myApps.contains { $0.id == newID })  // `a` hasn't seen it yet

        await a.reloadFromDisk()                        // watcher path: IO off-main, republish on main
        #expect(a.myApps.contains { $0.id == newID && $0.name == "Remote" })
        #expect(a.myApps.count == initialCount + 1)
    }

    // MARK: - Provisional fresh-install seed (data-loss guard)

    /// The reported catastrophe: a fresh-install seed must NOT be persisted while
    /// the iCloud mirror still holds real data that hasn't downloaded yet —
    /// persisting it lets the mirror push a one-app default over the real cloud
    /// index and wipe every device. The seed stays in memory until
    /// `commitProvisionalSeedIfNeeded()` confirms the cloud is genuinely empty.
    @Test("fresh seed is not persisted while the cloud already holds an index")
    func seedStaysProvisionalWhenCloudHasState() async throws {
        await MyAppStore.clearStorage()
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cloud.appendingPathComponent("state"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cloud.appendingPathComponent("state/index.json"))

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()                                          // fresh-install branch
            let localIndex = PupaStorage.stateRoot.appendingPathComponent("index.json")
            #expect(store.myApps.count == 1)                                 // shows the provisional default
            #expect(!FileManager.default.fileExists(atPath: localIndex.path))  // but never wrote it

            await store.commitProvisionalSeedIfNeeded()
            #expect(!FileManager.default.fileExists(atPath: localIndex.path))  // still waiting — cloud has data
        }
    }

    /// The same guard must hold when the cloud index is present only as a
    /// not-yet-downloaded `.icloud` placeholder — the exact fresh-reinstall race.
    @Test("fresh seed is not persisted when the cloud index is an undownloaded placeholder")
    func seedStaysProvisionalWhenCloudIndexIsPlaceholder() async throws {
        await MyAppStore.clearStorage()
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cloud.appendingPathComponent("state"), withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: cloud.appendingPathComponent("state/.index.json.icloud"))

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()
            await store.commitProvisionalSeedIfNeeded()
            let localIndex = PupaStorage.stateRoot.appendingPathComponent("index.json")
            #expect(!FileManager.default.fileExists(atPath: localIndex.path))  // placeholder counts as "cloud has data"
        }
    }

    /// A genuine fresh install (cloud truly empty) must commit the default so it
    /// persists locally and mirrors out — otherwise a brand-new user gets nothing.
    @Test("genuine fresh install commits the seed once the cloud is confirmed empty")
    func seedCommitsWhenCloudEmpty() async throws {
        await MyAppStore.clearStorage()
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()
            let localIndex = PupaStorage.stateRoot.appendingPathComponent("index.json")
            #expect(!FileManager.default.fileExists(atPath: localIndex.path))  // provisional, not yet written

            await store.commitProvisionalSeedIfNeeded()
            #expect(FileManager.default.fileExists(atPath: localIndex.path))   // committed
            #expect(store.myApps.count == 1)
        }
    }

    // MARK: - Sync-removal warning + undo

    /// A reload that drops an app another device deleted must surface it for undo
    /// (not silently vanish), and undo must bring it back.
    @Test("a sync reload that drops an app surfaces it for undo, and undo restores it")
    func syncRemovalDetectedAndUndoable() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        await a.commitProvisionalSeedIfNeeded()
        let keptId = a.addMyApp(typeId: "tracker", name: "Kept", iconSystemName: "star")
        let doomedId = a.addMyApp(typeId: "tracker", name: "Doomed", iconSystemName: "trash")

        // Another device (a second store on the same disk) deletes "Doomed".
        let b = MyAppStore()
        b.removeMyApp(doomedId)

        await a.reloadFromDisk()                                        // pulls the removal in
        #expect(!a.myApps.contains { $0.id == doomedId })              // dropped from the list
        #expect(a.pendingSyncRemovals.contains { $0.id == doomedId })  // but surfaced for undo
        #expect(a.myApps.contains { $0.id == keptId })                 // unrelated app untouched

        a.undoSyncRemovals()
        #expect(a.myApps.contains { $0.id == doomedId && $0.name == "Doomed" })  // restored
        #expect(a.pendingSyncRemovals.isEmpty)                         // banner cleared
    }

    /// Deleting an app on THIS device must never trigger the removal banner —
    /// `removeMyApp` already dropped it, so a subsequent reload sees no change.
    @Test("a local delete does not surface as a sync removal")
    func localDeleteNotFlaggedAsSyncRemoval() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        await store.commitProvisionalSeedIfNeeded()
        let id = store.addMyApp(typeId: "tracker", name: "Mine", iconSystemName: "star")
        store.removeMyApp(id)               // local delete
        await store.reloadFromDisk()
        #expect(store.pendingSyncRemovals.isEmpty)   // not flagged — the user did it here
    }

    @Test("MyApps survive an iCloud toggle and mirror up when iCloud is on")
    func toggleOffKeepsAppsAndMirrorsUp() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Keep", iconSystemName: "star")

        // iCloud "off" (no mirror root): the canonical tree is always local, so
        // a relaunch still sees the app — this is the pupa#110 "app looks lost"
        // regression, now impossible because `activeRoot` never switches roots.
        #expect(PupaStorage.cloudMirrorRoot == nil)
        #expect(MyAppStore().myApps.contains { $0.id == id })

        // iCloud "on": converge mirrors the local tree up; local is untouched.
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try await TestStorage.withCloudMirror(cloud) {
            StorageMirror.converge(localRoot: PupaStorage.activeRoot, cloudRoot: cloud)

            #expect(MyAppStore().myApps.contains { $0.id == id })       // still local
            let mirrored = cloud.appendingPathComponent("state/apps/\(id.uuidString).json")
            #expect(FileManager.default.fileExists(atPath: mirrored.path))  // and now in iCloud
        }
    }

    @Test("MyAppStore removeMyApp deletes that app's file")
    func removeMyAppDeletesFile() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Doomed", iconSystemName: "trash")
        let appURL = PupaStorage.stateRoot
            .appendingPathComponent("apps")
            .appendingPathComponent("\(id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: appURL.path))

        store.removeMyApp(id)
        #expect(!FileManager.default.fileExists(atPath: appURL.path))
    }

    @Test("MemoryStore write persists and reloads in a fresh instance")
    func memoryStoreRoundTrip() throws {
        let root = TestStorage.root.appendingPathComponent("mem-\(UUID().uuidString)", isDirectory: true)
        let writer = MemoryStore(rootOverride: root)
        try writer.writeFile(path: "notes/diet.md", content: "kale")

        let reader = MemoryStore(rootOverride: root)
        #expect(try reader.readFile(path: "notes/diet.md").content == "kale")
    }

    // MARK: - Efficiency: only the changed file re-syncs

    /// Mutating one MyApp must rewrite **only** that app's file — unchanged
    /// app files are left byte-for-byte untouched (dirty-hash skip), so iCloud
    /// uploads the minimum. Proven via modification dates: pre-stamp every file
    /// to the distant past, mutate one app, then assert only that file moved.
    @Test("A mutation rewrites only the changed app file, not the others")
    func dirtyHashWritesOnlyChangedFile() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let a = store.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "a.circle")
        let b = store.addMyApp(typeId: "tracker", name: "Bravo", iconSystemName: "b.circle")

        func appURL(_ id: UUID) -> URL {
            PupaStorage.stateRoot.appendingPathComponent("apps")
                .appendingPathComponent("\(id.uuidString).json")
        }
        let fm = FileManager.default
        // Stamp both app files to the distant past so any rewrite is unambiguous.
        let old = Date(timeIntervalSince1970: 0)
        for id in [a, b] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: appURL(id).path)
        }

        // Mutate only Bravo.
        store.renameMyApp(b, to: "Bravo-2")

        let aDate = try fm.attributesOfItem(atPath: appURL(a).path)[.modificationDate] as! Date
        let bDate = try fm.attributesOfItem(atPath: appURL(b).path)[.modificationDate] as! Date
        #expect(aDate == old)          // Alpha untouched — not re-uploaded.
        #expect(bDate > old)           // Bravo rewritten — the only sync.
    }

    /// A persist that changes nothing rewrites nothing (idempotent, no churn).
    @Test("Re-selecting the active app with no change rewrites no app file")
    func noOpPersistWritesNothing() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let a = store.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "a.circle")

        func appURL(_ id: UUID) -> URL {
            PupaStorage.stateRoot.appendingPathComponent("apps")
                .appendingPathComponent("\(id.uuidString).json")
        }
        let fm = FileManager.default
        let old = Date(timeIntervalSince1970: 0)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: appURL(a).path)

        // setActive to the already-active app: state is identical → no app write.
        store.setActive(a)

        let aDate = try fm.attributesOfItem(atPath: appURL(a).path)[.modificationDate] as! Date
        #expect(aDate == old)
    }

    // MARK: - Regression: rapid successive writes (pupa#120)

    /// Hammering one tracker item with back-to-back patches must persist every
    /// write in order; a fresh store loads the final value. Guards the
    /// uncoordinated atomic write path — dropping `NSFileCoordinator` must not
    /// drop, reorder, or tear a rapid burst of persists (the kanban-reorder
    /// hot path).
    @Test("Rapid successive patches persist the final value to disk")
    func rapidPatchesPersistFinalValue() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Board", iconSystemName: "star")
        store.setTracker(
            title: "Board",
            fields: [FieldDef(name: "status", type: .select, options: ["todo", "doing", "done"])],
            myAppId: id)
        guard let itemId = store.addItem(["status": "todo"], myAppId: id) else {
            Issue.record("addItem returned nil"); return
        }

        let sequence = ["doing", "todo", "done", "doing", "done"]
        for _ in 0..<10 {
            for v in sequence { _ = store.patchItem(id: itemId, with: ["status": v], myAppId: id) }
        }
        let final = sequence.last!

        // A fresh instance loads the last written value straight from disk.
        let reader = MyAppStore()
        let item: TrackerItem? = reader.myApps.first { $0.id == id }.flatMap { app in
            if case .tracker(let t) = app.canvas { return t.items.first { $0.id == itemId } }
            return nil
        }
        #expect(item?.values["status"] == final)
    }
}
