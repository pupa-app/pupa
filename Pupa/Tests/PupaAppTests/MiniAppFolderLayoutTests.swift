import Foundation
import Testing
@testable import PupaApp

/// The UI-only MiniApp sidebar-folder feature. Guards the core invariant —
/// folder layout never reaches a marketplace export — plus mutator behaviour
/// and `index.json` persistence.
@MainActor
@Suite("MiniApp folders", .serialized)
struct MiniAppFolderLayoutTests {

    init() { TestStorage.activate() }

    /// Fresh store with two extra apps; returns (store, [appId]).
    private func makeTwoApps() async -> (MiniAppStore, [UUID]) {
        await MiniAppStore.clearStorage()
        let store = MiniAppStore()
        let a = store.addMiniApp(typeId: "tracker", name: "Alpha", iconSystemName: "a.circle")
        let b = store.addMiniApp(typeId: "tracker", name: "Bravo", iconSystemName: "b.circle")
        return (store, [a, b])
    }

    private func tempMemory() -> MemoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-miniapp-folder-tests-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: dir)
    }

    // MARK: - Export invisibility invariant

    @Test("Folder layout never leaks into an exported bundle")
    func folderDataAbsentFromBundle() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMiniAppFolder(name: "Work", containing: ids[0])
        store.setMiniAppFolder(miniAppId: ids[1], folderId: fid)
        #expect(!store.miniAppFolders.folders.isEmpty)   // layout exists off-model

        let app = store.miniApp(withId: ids[0])!
        let bundle = MiniAppExporter.makeBundle(
            app: app,
            options: .init(selectedComponentIds: Set(app.components.map(\.id)),
                           includeRecords: true, includeMemories: false),
            memory: tempMemory())
        let json = String(data: try bundle.encoded(), encoding: .utf8)!
        for needle in ["Work", "miniAppFolders", "assignments", "folderId"] {
            #expect(!json.contains(needle), "exported bundle leaked \"\(needle)\"")
        }
    }

    @Test("Folder data lives in index.json, not an app file")
    func folderDataInIndexNotAppFile() async throws {
        let (store, ids) = await makeTwoApps()
        _ = store.createMiniAppFolder(name: "Errands", containing: ids[0])

        let root = PupaStorage.stateRoot
        let appJSON = String(data: CloudDocument.read(
            root.appendingPathComponent("apps/\(ids[0].uuidString).json"))!, encoding: .utf8)!
        let indexJSON = String(data: CloudDocument.read(
            root.appendingPathComponent("index.json"))!, encoding: .utf8)!

        #expect(!appJSON.contains("Errands"))
        #expect(indexJSON.contains("Errands"))
        #expect(indexJSON.contains("miniAppFolders"))
    }

    // MARK: - Mutators

    @Test("Create makes a folder holding the seed app")
    func createHoldsSeedApp() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMiniAppFolder(name: "Work", containing: ids[0])
        #expect(store.miniAppFolders.folders.map(\.name) == ["Work"])
        #expect(store.miniAppFolders.miniAppIds(inFolder: fid) == [ids[0].uuidString])
        #expect(store.miniAppFolders.folderId(forMiniApp: ids[0]) == fid)
    }

    @Test("Assigning to an unknown folder makes the app loose")
    func assignUnknownFolderLoosens() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMiniAppFolder(name: "Work", containing: ids[0])
        store.setMiniAppFolder(miniAppId: ids[0], folderId: "nope")
        #expect(store.miniAppFolders.folderId(forMiniApp: ids[0]) == nil)
        #expect(store.miniAppFolders.folder(id: fid) == nil)   // emptied → pruned
    }

    @Test("A folder is pruned when its last member leaves")
    func pruneOnLastMemberLeaving() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMiniAppFolder(name: "Work", containing: ids[0])
        store.setMiniAppFolder(miniAppId: ids[1], folderId: fid)
        store.setMiniAppFolder(miniAppId: ids[0], folderId: nil)
        #expect(store.miniAppFolders.folder(id: fid) != nil)   // still holds Bravo
        store.setMiniAppFolder(miniAppId: ids[1], folderId: nil)
        #expect(store.miniAppFolders.folders.isEmpty)
    }

    @Test("Rename changes the folder name in place")
    func renameFolder() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMiniAppFolder(name: "Work", containing: ids[0])
        store.renameMiniAppFolder(folderId: fid, name: "Personal")
        #expect(store.miniAppFolders.folder(id: fid)?.name == "Personal")
        #expect(store.miniAppFolders.miniAppIds(inFolder: fid) == [ids[0].uuidString])
    }

    @Test("Removing a folder returns its apps to the top level")
    func removeFolderLoosensMembers() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMiniAppFolder(name: "Work", containing: ids[0])
        store.setMiniAppFolder(miniAppId: ids[1], folderId: fid)
        store.removeMiniAppFolder(folderId: fid)
        #expect(store.miniAppFolders.folders.isEmpty)
        #expect(store.miniAppFolders.assignments.isEmpty)
    }

    @Test("Deleting a MiniApp drops its folder assignment")
    func deleteDropsAssignment() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMiniAppFolder(name: "Work", containing: ids[0])
        store.setMiniAppFolder(miniAppId: ids[1], folderId: fid)
        store.removeMiniApp(ids[1])
        #expect(store.miniAppFolders.miniAppIds(inFolder: fid) == [ids[0].uuidString])
        store.removeMiniApp(ids[0])
        #expect(store.miniAppFolders.folders.isEmpty)   // emptied → pruned
    }

    // MARK: - Archive interaction

    @Test("Archiving keeps the assignment so unarchiving restores the folder")
    func archiveKeepsAssignment() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMiniAppFolder(name: "Work", containing: ids[0])
        store.setMiniAppArchived(ids[0], true)
        #expect(store.miniAppFolders.folderId(forMiniApp: ids[0]) == fid)
        store.setMiniAppArchived(ids[0], false)
        #expect(store.miniAppFolders.folderId(forMiniApp: ids[0]) == fid)
    }

    // MARK: - Persistence

    @Test("Folder layout round-trips through a fresh store")
    func persistenceRoundTrip() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMiniAppFolder(name: "Work", containing: ids[0])
        store.setMiniAppFolder(miniAppId: ids[1], folderId: fid)

        let reader = MiniAppStore()   // reloads the same on-disk root
        #expect(reader.miniAppFolders.folders.map(\.name) == ["Work"])
        #expect(Set(reader.miniAppFolders.miniAppIds(inFolder: fid))
                == Set(ids.map(\.uuidString)))
    }

    @Test("Old folder index migrates without moving app files")
    func oldIndexMigrates() async throws {
        let (store, ids) = await makeTwoApps()
        let folderId = store.createMiniAppFolder(name: "Work", containing: ids[0])
        let indexFile = PupaStorage.stateRoot.appendingPathComponent("index.json")
        var index = try JSONSerialization.jsonObject(with: CloudDocument.read(indexFile)!) as! [String: Any]
        index["myAppFolders"] = index.removeValue(forKey: "miniAppFolders")
        try CloudDocument.write(try JSONSerialization.data(withJSONObject: index), to: indexFile)

        let reader = MiniAppStore()
        #expect(reader.miniAppFolders.folderId(forMiniApp: ids[0]) == folderId)
        #expect(reader.miniApp(withId: ids[0]) != nil)
        #expect(FileManager.default.fileExists(atPath: PupaStorage.stateRoot
            .appendingPathComponent("apps/\(ids[0].uuidString).json").path))
        let secondReader = MiniAppStore()
        #expect(secondReader.miniAppFolders.folderId(forMiniApp: ids[0]) == folderId)
        let migrated = try JSONSerialization.jsonObject(with: CloudDocument.read(indexFile)!) as! [String: Any]
        #expect(migrated["miniAppFolders"] != nil)
        #expect(migrated["myAppFolders"] == nil)

        var mixed = migrated
        mixed["myAppFolders"] = migrated["miniAppFolders"]
        try CloudDocument.write(try JSONSerialization.data(withJSONObject: mixed), to: indexFile)
        let mixedReader = MiniAppStore()
        #expect(mixedReader.miniAppFolders.folderId(forMiniApp: ids[0]) == folderId)
        let cleaned = try JSONSerialization.jsonObject(with: CloudDocument.read(indexFile)!) as! [String: Any]
        #expect(cleaned["myAppFolders"] == nil)
    }

    @Test("Old history event app IDs decode and write the new key")
    func oldHistoryEventDecodes() throws {
        let appId = UUID()
        let event = ItemEvent(miniAppId: appId, componentId: "tracker-1",
                              kind: .added, actor: .user)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
        object["myAppId"] = object.removeValue(forKey: "miniAppId")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ItemEvent.self, from: oldData)
        #expect(decoded.miniAppId == appId)
        let newObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
        #expect(newObject["miniAppId"] != nil)
        #expect(newObject["myAppId"] == nil)
    }

    @Test("Legacy index.json without miniAppFolders still decodes")
    func legacyIndexDecodes() async throws {
        let (store, ids) = await makeTwoApps()
        _ = store.createMiniAppFolder(name: "Work", containing: ids[0])

        // Strip the key to simulate a pre-feature index.json.
        let indexFile = PupaStorage.stateRoot.appendingPathComponent("index.json")
        var obj = try JSONSerialization.jsonObject(with: CloudDocument.read(indexFile)!) as! [String: Any]
        obj.removeValue(forKey: "miniAppFolders")
        try CloudDocument.write(try JSONSerialization.data(withJSONObject: obj), to: indexFile)

        let reader = MiniAppStore()
        #expect(reader.miniApp(withId: ids[0]) != nil)
        #expect(reader.miniAppFolders.folders.isEmpty)
    }
}
