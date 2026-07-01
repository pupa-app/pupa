import Foundation
import Testing
@testable import PupaApp
@testable import AGUIKit

/// Component lock: a locked component refuses every mutating tool/mutation
/// (with a clear "locked" result to the agent) while reads still work.
@MainActor
@Suite("Component lock")
struct ComponentLockTests {

    init() { TestStorage.activate() }

    private func freshTrackerStore() -> (MyAppStore, UUID, String) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.setTracker(title: "Test", fields: [FieldDef(name: "title", type: .text)], myAppId: myApp.id)
        let cid = store.myApps.first { $0.id == myApp.id }!
            .components.first { $0.kindString == "tracker" }!.id
        return (store, myApp.id, cid)
    }

    private func trackerItemCount(_ store: MyAppStore, _ id: UUID) -> Int {
        for c in store.myApps.first(where: { $0.id == id })?.components ?? [] {
            if case .tracker(let t) = c.body { return t.items.count }
        }
        return -1
    }

    // MARK: - Store-level backstop

    @Test("locked component refuses direct mutations; unlock restores them")
    func backstopBlocksAndRestores() {
        let (store, id, cid) = freshTrackerStore()
        store.setComponentLocked(componentId: cid, locked: true, myAppId: id)
        #expect(store.isComponentLocked(componentId: cid, myAppId: id))

        store.resetLockFlag()
        let added = store.addItem(["title": "x"], myAppId: id)
        #expect(added == nil)                       // refused
        #expect(store.lastWriteBlockedByLock)       // flagged for the tool layer
        #expect(trackerItemCount(store, id) == 0)   // no write

        store.setComponentLocked(componentId: cid, locked: false, myAppId: id)
        store.resetLockFlag()
        #expect(store.addItem(["title": "x"], myAppId: id) != nil)
        #expect(!store.lastWriteBlockedByLock)
        #expect(trackerItemCount(store, id) == 1)
    }

    @Test("setComponentLocked is idempotent and captions the change feed")
    func lockEmitsEvent() {
        let (store, id, cid) = freshTrackerStore()
        #expect(store.setComponentLocked(componentId: cid, locked: true, myAppId: id))
        #expect(!store.setComponentLocked(componentId: cid, locked: true, myAppId: id))  // no-op
        let last = store.itemEventLog.events(forMyApp: id).last
        #expect(last?.kind == .locked)
    }

    // MARK: - Tool layer (agent-facing)

    @Test("mutating tool on a locked component returns a locked result; reads still work")
    func toolGating() async throws {
        let (store, id, cid) = freshTrackerStore()
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: id)
        store.setComponentLocked(componentId: cid, locked: true, myAppId: id)

        let add = registry.resolve("addTrackerItems")!
        let addResult = try await add.handler(.object(["items": .array([.object(["title": "x"])])]))
        #expect(addResult["ok"]?.boolValue == false)
        #expect(addResult["locked"]?.boolValue == true)
        #expect(trackerItemCount(store, id) == 0)

        // Read-only tool is exempt.
        let list = registry.resolve("listTrackerItems")!
        let listResult = try await list.handler(.object([:]))
        #expect(listResult["ok"]?.boolValue == true)
    }

    @Test("unlock tool re-enables mutations even while locked")
    func unlockToolAlwaysWorks() async throws {
        let (store, id, cid) = freshTrackerStore()
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: id)
        store.setComponentLocked(componentId: cid, locked: true, myAppId: id)

        let unlock = registry.resolve("setComponentLocked")!
        let result = try await unlock.handler(.object(["componentId": .string(cid), "locked": .bool(false)]))
        #expect(result["ok"]?.boolValue == true)
        #expect(!store.isComponentLocked(componentId: cid, myAppId: id))
    }

    // MARK: - Compatibility

    @Test("Component decodes without isLocked (old/imported data) as unlocked")
    func decodesLegacyComponent() throws {
        let legacy = """
        {"id":"tracker-1","name":"T","iconSystemName":"list","body":{"kind":"empty"}}
        """.data(using: .utf8)!
        let comp = try JSONDecoder().decode(Component.self, from: legacy)
        #expect(comp.isLocked == false)

        // Round-trip preserves the flag.
        var locked = comp
        locked.isLocked = true
        let data = try JSONEncoder().encode(locked)
        #expect(try JSONDecoder().decode(Component.self, from: data).isLocked == true)
    }
}
