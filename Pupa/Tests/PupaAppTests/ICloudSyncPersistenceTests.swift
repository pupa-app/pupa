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
    func myAppStorePerFileRoundTrip() throws {
        MyAppStore.clearStorage()
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
        MyAppStore.clearStorage()
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

    @Test("MyApps survive an iCloud toggle and mirror up when iCloud is on")
    func toggleOffKeepsAppsAndMirrorsUp() throws {
        MyAppStore.clearStorage()
        let store = MyAppStore()
        let id = store.addMyApp(typeId: "tracker", name: "Keep", iconSystemName: "star")

        // iCloud "off" (no mirror root): the canonical tree is always local, so
        // a relaunch still sees the app — this is the pupa#110 "app looks lost"
        // regression, now impossible because `activeRoot` never switches roots.
        #expect(PupaStorage.cloudMirrorRoot == nil)
        #expect(MyAppStore().myApps.contains { $0.id == id })

        // iCloud "on": converge mirrors the local tree up; local is untouched.
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        PupaStorage.cloudMirrorOverride = cloud
        defer { PupaStorage.cloudMirrorOverride = nil }
        StorageMirror.converge(localRoot: PupaStorage.activeRoot, cloudRoot: cloud)

        #expect(MyAppStore().myApps.contains { $0.id == id })       // still local
        let mirrored = cloud.appendingPathComponent("state/apps/\(id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: mirrored.path))  // and now in iCloud
    }

    @Test("MyAppStore removeMyApp deletes that app's file")
    func removeMyAppDeletesFile() throws {
        MyAppStore.clearStorage()
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
    func dirtyHashWritesOnlyChangedFile() throws {
        MyAppStore.clearStorage()
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
    func noOpPersistWritesNothing() throws {
        MyAppStore.clearStorage()
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
    func rapidPatchesPersistFinalValue() throws {
        MyAppStore.clearStorage()
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
