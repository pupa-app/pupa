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
}
