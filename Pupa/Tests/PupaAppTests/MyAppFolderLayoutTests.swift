import Foundation
import Testing
@testable import PupaApp

/// The UI-only MyApp sidebar-folder feature. Guards the core invariant —
/// folder layout never reaches a marketplace export — plus mutator behaviour
/// and `index.json` persistence.
@MainActor
@Suite("MyApp folders", .serialized)
struct MyAppFolderLayoutTests {

    init() { TestStorage.activate() }

    /// Fresh store with two extra apps; returns (store, [appId]).
    private func makeTwoApps() async -> (MyAppStore, [UUID]) {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let a = store.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "a.circle")
        let b = store.addMyApp(typeId: "tracker", name: "Bravo", iconSystemName: "b.circle")
        return (store, [a, b])
    }

    private func tempMemory() -> MemoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-myapp-folder-tests-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: dir)
    }

    // MARK: - Export invisibility invariant

    @Test("Folder layout never leaks into an exported bundle")
    func folderDataAbsentFromBundle() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMyAppFolder(name: "Work", containing: ids[0])
        store.setMyAppFolder(myAppId: ids[1], folderId: fid)
        #expect(!store.myAppFolders.folders.isEmpty)   // layout exists off-model

        let app = store.myApp(withId: ids[0])!
        let bundle = MyAppExporter.makeBundle(
            app: app,
            options: .init(selectedComponentIds: Set(app.components.map(\.id)),
                           includeRecords: true, includeMemories: false),
            memory: tempMemory())
        let json = String(data: try bundle.encoded(), encoding: .utf8)!
        for needle in ["Work", "myAppFolders", "assignments", "folderId"] {
            #expect(!json.contains(needle), "exported bundle leaked \"\(needle)\"")
        }
    }

    @Test("Folder data lives in index.json, not an app file")
    func folderDataInIndexNotAppFile() async throws {
        let (store, ids) = await makeTwoApps()
        _ = store.createMyAppFolder(name: "Errands", containing: ids[0])

        let root = PupaStorage.stateRoot
        let appJSON = String(data: CloudDocument.read(
            root.appendingPathComponent("apps/\(ids[0].uuidString).json"))!, encoding: .utf8)!
        let indexJSON = String(data: CloudDocument.read(
            root.appendingPathComponent("index.json"))!, encoding: .utf8)!

        #expect(!appJSON.contains("Errands"))
        #expect(indexJSON.contains("Errands"))
        #expect(indexJSON.contains("myAppFolders"))
    }

    // MARK: - Mutators

    @Test("Create makes a folder holding the seed app")
    func createHoldsSeedApp() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMyAppFolder(name: "Work", containing: ids[0])
        #expect(store.myAppFolders.folders.map(\.name) == ["Work"])
        #expect(store.myAppFolders.myAppIds(inFolder: fid) == [ids[0].uuidString])
        #expect(store.myAppFolders.folderId(forMyApp: ids[0]) == fid)
    }

    @Test("Assigning to an unknown folder makes the app loose")
    func assignUnknownFolderLoosens() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMyAppFolder(name: "Work", containing: ids[0])
        store.setMyAppFolder(myAppId: ids[0], folderId: "nope")
        #expect(store.myAppFolders.folderId(forMyApp: ids[0]) == nil)
        #expect(store.myAppFolders.folder(id: fid) == nil)   // emptied → pruned
    }

    @Test("A folder is pruned when its last member leaves")
    func pruneOnLastMemberLeaving() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMyAppFolder(name: "Work", containing: ids[0])
        store.setMyAppFolder(myAppId: ids[1], folderId: fid)
        store.setMyAppFolder(myAppId: ids[0], folderId: nil)
        #expect(store.myAppFolders.folder(id: fid) != nil)   // still holds Bravo
        store.setMyAppFolder(myAppId: ids[1], folderId: nil)
        #expect(store.myAppFolders.folders.isEmpty)
    }

    @Test("Rename changes the folder name in place")
    func renameFolder() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMyAppFolder(name: "Work", containing: ids[0])
        store.renameMyAppFolder(folderId: fid, name: "Personal")
        #expect(store.myAppFolders.folder(id: fid)?.name == "Personal")
        #expect(store.myAppFolders.myAppIds(inFolder: fid) == [ids[0].uuidString])
    }

    @Test("Removing a folder returns its apps to the top level")
    func removeFolderLoosensMembers() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMyAppFolder(name: "Work", containing: ids[0])
        store.setMyAppFolder(myAppId: ids[1], folderId: fid)
        store.removeMyAppFolder(folderId: fid)
        #expect(store.myAppFolders.folders.isEmpty)
        #expect(store.myAppFolders.assignments.isEmpty)
    }

    @Test("Deleting a MyApp drops its folder assignment")
    func deleteDropsAssignment() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMyAppFolder(name: "Work", containing: ids[0])
        store.setMyAppFolder(myAppId: ids[1], folderId: fid)
        store.removeMyApp(ids[1])
        #expect(store.myAppFolders.myAppIds(inFolder: fid) == [ids[0].uuidString])
        store.removeMyApp(ids[0])
        #expect(store.myAppFolders.folders.isEmpty)   // emptied → pruned
    }

    // MARK: - Archive interaction

    @Test("Archiving keeps the assignment so unarchiving restores the folder")
    func archiveKeepsAssignment() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMyAppFolder(name: "Work", containing: ids[0])
        store.setMyAppArchived(ids[0], true)
        #expect(store.myAppFolders.folderId(forMyApp: ids[0]) == fid)
        store.setMyAppArchived(ids[0], false)
        #expect(store.myAppFolders.folderId(forMyApp: ids[0]) == fid)
    }

    // MARK: - Persistence

    @Test("Folder layout round-trips through a fresh store")
    func persistenceRoundTrip() async throws {
        let (store, ids) = await makeTwoApps()
        let fid = store.createMyAppFolder(name: "Work", containing: ids[0])
        store.setMyAppFolder(myAppId: ids[1], folderId: fid)

        let reader = MyAppStore()   // reloads the same on-disk root
        #expect(reader.myAppFolders.folders.map(\.name) == ["Work"])
        #expect(Set(reader.myAppFolders.myAppIds(inFolder: fid))
                == Set(ids.map(\.uuidString)))
    }

    @Test("Legacy index.json without myAppFolders still decodes")
    func legacyIndexDecodes() async throws {
        let (store, ids) = await makeTwoApps()
        _ = store.createMyAppFolder(name: "Work", containing: ids[0])

        // Strip the key to simulate a pre-feature index.json.
        let indexFile = PupaStorage.stateRoot.appendingPathComponent("index.json")
        var obj = try JSONSerialization.jsonObject(with: CloudDocument.read(indexFile)!) as! [String: Any]
        obj.removeValue(forKey: "myAppFolders")
        try CloudDocument.write(try JSONSerialization.data(withJSONObject: obj), to: indexFile)

        let reader = MyAppStore()
        #expect(reader.myApp(withId: ids[0]) != nil)
        #expect(reader.myAppFolders.folders.isEmpty)
    }
}
