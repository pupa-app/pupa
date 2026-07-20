import Foundation
import Testing
@testable import PupaApp

/// The transient `CanvasEvent` stream is emitted from the single mutation
/// choke-point (`patchItem`) alongside — never instead of — the persisted
/// `ItemEvent` History feed.
@MainActor
@Suite("Canvas event emission")
struct CanvasEventEmissionTests {

    init() { TestStorage.activate() }

    /// A tracker MyApp in kanban mode with `Status` as the column field and
    /// one item parked in "Doing". Returns store, appId, and the item id.
    private func freshKanban() -> (MyAppStore, UUID, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.setTracker(title: "Board", fields: [
            FieldDef(name: "title", type: .text),
            FieldDef(name: "Status", type: .select, options: ["Doing", "Review", "Done"])
        ], myAppId: myApp.id)
        _ = store.setTrackerViewMode(.kanban, columnField: "Status", myAppId: myApp.id)
        let item = store.addItem(["title": "Ship v2", "Status": "Doing"], myAppId: myApp.id)!
        return (store, myApp.id, item)
    }

    @Test("moving across the column field publishes one item.moved event")
    func columnMovePublishes() {
        let (store, appId, item) = freshKanban()
        var events: [CanvasEvent] = []
        store.onCanvasEvent = { events.append($0) }

        _ = store.patchItem(id: item, with: ["Status": "Review"], myAppId: appId)

        #expect(events.count == 1)
        let ev = try! #require(events.first)
        #expect(ev.type == .itemMoved)
        #expect(ev.itemId == item)
        #expect(ev.fromColumn == "Doing")
        #expect(ev.toColumn == "Review")
        #expect(ev.itemTitle == "Ship v2")
        #expect(ev.matchFields["toColumn"] == "Review")
    }

    @Test("transitionId is stable for the same (item, field, from→to)")
    func stableTransitionId() {
        let (store, appId, item) = freshKanban()
        var ids: [String] = []
        store.onCanvasEvent = { ids.append($0.transitionId) }

        _ = store.patchItem(id: item, with: ["Status": "Review"], myAppId: appId)
        // Move back then forward again — same string transition, same id.
        _ = store.patchItem(id: item, with: ["Status": "Doing"], myAppId: appId)
        _ = store.patchItem(id: item, with: ["Status": "Review"], myAppId: appId)

        #expect(ids.count == 3)
        #expect(ids[0] == ids[2])   // identical Doing→Review transitions share an id
        #expect(ids[0] != ids[1])   // Review→Doing is a different transition
    }

    @Test("patching a non-column field publishes no item.moved event")
    func nonColumnFieldSilent() {
        let (store, appId, item) = freshKanban()
        var events: [CanvasEvent] = []
        store.onCanvasEvent = { events.append($0) }

        _ = store.patchItem(id: item, with: ["title": "Ship v3"], myAppId: appId)
        #expect(events.isEmpty)
    }

    @Test("no regression: the ItemEvent History feed still records .patched")
    func historyStillRecords() {
        let (store, appId, item) = freshKanban()
        _ = store.patchItem(id: item, with: ["Status": "Review"], myAppId: appId)
        let patched = store.itemEventLog.events(forMyApp: appId).filter { $0.kind == .patched }
        #expect(patched.contains { $0.itemId == item })
    }
}
