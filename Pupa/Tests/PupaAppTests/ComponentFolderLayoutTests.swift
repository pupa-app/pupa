import Foundation
import Testing
@testable import PupaApp

/// The UI-only component-folder feature (issue #138). Guards the core
/// invariant — folder layout never reaches the agent or a marketplace export —
/// plus mutator behaviour and `index.json` persistence.
@MainActor
@Suite("Component folders", .serialized)
struct ComponentFolderLayoutTests {

    init() { TestStorage.activate() }

    /// Fresh store with one app holding two components; returns (store, appId, [id]).
    private func makeAppWithTwoComponents() async -> (MyAppStore, UUID, [String]) {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let appId = store.addMyApp(typeId: "tracker", name: "Folders", iconSystemName: "star")
        let a = store.addComponent(kind: "tracker", name: "Alpha", iconSystemName: "a.circle", myAppId: appId)!
        let b = store.addComponent(kind: "tracker", name: "Bravo", iconSystemName: "b.circle", myAppId: appId)!
        return (store, appId, [a, b])
    }

    // MARK: - Agent / export invisibility invariant

    @Test("Folder layout never leaks into an encoded MyApp")
    func folderDataAbsentFromMyAppEncoding() async throws {
        let (store, appId, ids) = await makeAppWithTwoComponents()
        store.combineComponentsIntoFolder(ids[0], ids[1], myAppId: appId)
        #expect(!store.componentFolders.isEmpty)   // layout exists off-model

        let app = store.myApp(withId: appId)!
        let json = String(data: try JSONEncoder().encode(app), encoding: .utf8)!
        for needle in ["New Folder", "componentFolders", "assignments", "folderId"] {
            #expect(!json.contains(needle), "encoded MyApp leaked \"\(needle)\"")
        }
    }

    @Test("Folder data lives in index.json, not the app file")
    func folderDataInIndexNotAppFile() async throws {
        let (store, appId, ids) = await makeAppWithTwoComponents()
        store.combineComponentsIntoFolder(ids[0], ids[1], myAppId: appId)

        let root = PupaStorage.stateRoot
        let appFile = root.appendingPathComponent("apps/\(appId.uuidString).json")
        let indexFile = root.appendingPathComponent("index.json")
        let appJSON = String(data: CloudDocument.read(appFile)!, encoding: .utf8)!
        let indexJSON = String(data: CloudDocument.read(indexFile)!, encoding: .utf8)!

        #expect(!appJSON.contains("New Folder"))
        #expect(indexJSON.contains("New Folder"))
        #expect(indexJSON.contains("componentFolders"))
    }

    // MARK: - Mutators

    @Test("Combine creates a folder holding both components")
    func combineCreatesFolder() async throws {
        let (store, appId, ids) = await makeAppWithTwoComponents()
        store.combineComponentsIntoFolder(ids[0], ids[1], myAppId: appId)
        let layout = store.componentFolderLayout(forMyApp: appId)
        #expect(layout.folders.count == 1)
        let fid = layout.folders[0].id
        #expect(Set(layout.componentIds(inFolder: fid)) == Set(ids))
    }

    @Test("Combine is a no-op on the same tile")
    func combineSameTileNoOp() async throws {
        let (store, appId, ids) = await makeAppWithTwoComponents()
        store.combineComponentsIntoFolder(ids[0], ids[0], myAppId: appId)
        #expect(store.componentFolderLayout(forMyApp: appId).folders.isEmpty)
    }

    @Test("Dropping onto an existing folder adds the component")
    func dropOntoFolderAdds() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let appId = store.addMyApp(typeId: "tracker", name: "F", iconSystemName: "star")
        let a = store.addComponent(kind: "tracker", name: "A", iconSystemName: "a", myAppId: appId)!
        let b = store.addComponent(kind: "tracker", name: "B", iconSystemName: "b", myAppId: appId)!
        let c = store.addComponent(kind: "tracker", name: "C", iconSystemName: "c", myAppId: appId)!
        store.combineComponentsIntoFolder(a, b, myAppId: appId)
        let fid = store.componentFolderLayout(forMyApp: appId).folders[0].id
        store.setComponentFolder(componentId: c, folderId: fid, myAppId: appId)
        #expect(Set(store.componentFolderLayout(forMyApp: appId).componentIds(inFolder: fid)) == Set([a, b, c]))
    }

    @Test("Move out drops the assignment; last item auto-dissolves the folder")
    func moveOutAutoDissolves() async throws {
        let (store, appId, ids) = await makeAppWithTwoComponents()
        store.combineComponentsIntoFolder(ids[0], ids[1], myAppId: appId)
        store.setComponentFolder(componentId: ids[0], folderId: nil, myAppId: appId)
        // One member left → folder survives.
        #expect(store.componentFolderLayout(forMyApp: appId).folders.count == 1)
        store.setComponentFolder(componentId: ids[1], folderId: nil, myAppId: appId)
        // Empty → dissolved, and the whole app entry cleared.
        #expect(store.componentFolders[appId.uuidString] == nil)
    }

    @Test("Deleting a folder returns children to the top level")
    func deleteFolderReturnsChildren() async throws {
        let (store, appId, ids) = await makeAppWithTwoComponents()
        store.combineComponentsIntoFolder(ids[0], ids[1], myAppId: appId)
        let fid = store.componentFolderLayout(forMyApp: appId).folders[0].id
        store.removeComponentFolder(folderId: fid, myAppId: appId)
        // Folder gone, but the components themselves survive at the top level.
        #expect(store.componentFolders[appId.uuidString] == nil)
        let comps = Set(store.myApp(withId: appId)!.components.map(\.id))
        #expect(comps.isSuperset(of: Set(ids)))
    }

    @Test("Renaming a folder updates its name")
    func renameFolder() async throws {
        let (store, appId, ids) = await makeAppWithTwoComponents()
        store.combineComponentsIntoFolder(ids[0], ids[1], myAppId: appId)
        let fid = store.componentFolderLayout(forMyApp: appId).folders[0].id
        store.renameComponentFolder(folderId: fid, name: "Work", myAppId: appId)
        #expect(store.componentFolderLayout(forMyApp: appId).folders[0].name == "Work")
    }

    @Test("Removing a component prunes its stale assignment and empty folder")
    func removeComponentPrunes() async throws {
        // Three components (a store refuses to delete the last one), two foldered.
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        let appId = store.addMyApp(typeId: "tracker", name: "F", iconSystemName: "star")
        let a = store.addComponent(kind: "tracker", name: "A", iconSystemName: "a", myAppId: appId)!
        let b = store.addComponent(kind: "tracker", name: "B", iconSystemName: "b", myAppId: appId)!
        _ = store.addComponent(kind: "tracker", name: "C", iconSystemName: "c", myAppId: appId)!
        store.combineComponentsIntoFolder(a, b, myAppId: appId)

        store.removeComponent(componentId: a, myAppId: appId)
        let layout = store.componentFolderLayout(forMyApp: appId)
        #expect(layout.folderId(forComponent: a) == nil)
        // One member remains → folder still present.
        #expect(layout.folders.count == 1)
        store.removeComponent(componentId: b, myAppId: appId)
        #expect(store.componentFolders[appId.uuidString] == nil)
    }

    // MARK: - Persistence

    @Test("Folder layout round-trips through a fresh store")
    func persistenceRoundTrip() async throws {
        let (store, appId, ids) = await makeAppWithTwoComponents()
        store.combineComponentsIntoFolder(ids[0], ids[1], myAppId: appId)
        let fid = store.componentFolderLayout(forMyApp: appId).folders[0].id

        let reader = MyAppStore()   // reloads the same on-disk root
        let layout = reader.componentFolderLayout(forMyApp: appId)
        #expect(layout.folders.map(\.id) == [fid])
        #expect(Set(layout.componentIds(inFolder: fid)) == Set(ids))
    }

    @Test("Legacy index.json without componentFolders still decodes")
    func legacyIndexDecodes() async throws {
        let (store, appId, _) = await makeAppWithTwoComponents()
        _ = store

        // Strip the componentFolders key to simulate a pre-feature index.json.
        let indexFile = PupaStorage.stateRoot.appendingPathComponent("index.json")
        var obj = try JSONSerialization.jsonObject(with: CloudDocument.read(indexFile)!) as! [String: Any]
        obj.removeValue(forKey: "componentFolders")
        try CloudDocument.write(try JSONSerialization.data(withJSONObject: obj), to: indexFile)

        let reader = MyAppStore()
        #expect(reader.myApp(withId: appId) != nil)
        #expect(reader.componentFolders.isEmpty)
    }
}
