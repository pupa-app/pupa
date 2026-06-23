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
}
