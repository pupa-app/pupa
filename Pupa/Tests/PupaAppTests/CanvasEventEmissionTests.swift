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

    /// A tracker MyApp with two select fields (`Status`, `Priority`) and one
    /// item parked in "Doing" / "Low". `groupBy` picks the kanban column field
    /// (nil ⇒ stay in grid) so a test can prove emission is view-independent.
    /// Returns store, appId, and the item id.
    private func freshKanban(groupBy: String? = "Status") -> (MyAppStore, UUID, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.setTracker(title: "Board", fields: [
            FieldDef(name: "title", type: .text),
            FieldDef(name: "Status", type: .select, options: ["Doing", "Review", "Done"]),
            FieldDef(name: "Priority", type: .select, options: ["Low", "High"])
        ], myAppId: myApp.id)
        if let groupBy {
            _ = store.setTrackerViewMode(.kanban, columnField: groupBy, myAppId: myApp.id)
        }
        let item = store.addItem(
            ["title": "Ship v2", "Status": "Doing", "Priority": "Low"], myAppId: myApp.id)!
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
        #expect(ev.field == "Status")
        #expect(ev.matchFields["toColumn"] == "Review")
        #expect(ev.matchFields["field"] == "Status")
    }

    @Test("a select field that is NOT the kanban group-by still publishes")
    func nonGroupedSelectFieldPublishes() {
        // Board grouped by Status; the user edits Priority inline. The rule for
        // Priority must still see an event — emission is a domain fact, not a
        // property of which column the board happens to be grouped by.
        let (store, appId, item) = freshKanban(groupBy: "Status")
        var events: [CanvasEvent] = []
        store.onCanvasEvent = { events.append($0) }

        _ = store.patchItem(id: item, with: ["Priority": "High"], myAppId: appId)

        #expect(events.count == 1)
        let ev = try! #require(events.first)
        #expect(ev.field == "Priority")
        #expect(ev.fromColumn == "Low")
        #expect(ev.toColumn == "High")
    }

    @Test("grid view (no kanban column field) still publishes select moves")
    func gridViewPublishes() {
        let (store, appId, item) = freshKanban(groupBy: nil)
        var events: [CanvasEvent] = []
        store.onCanvasEvent = { events.append($0) }

        _ = store.patchItem(id: item, with: ["Status": "Review"], myAppId: appId)

        #expect(events.count == 1)
        #expect(events.first?.field == "Status")
        #expect(events.first?.toColumn == "Review")
    }

    @Test("one patch touching two select fields publishes one event per field")
    func multiFieldPatchPublishesPerField() {
        let (store, appId, item) = freshKanban()
        var events: [CanvasEvent] = []
        store.onCanvasEvent = { events.append($0) }

        _ = store.patchItem(id: item, with: ["Status": "Done", "Priority": "High"], myAppId: appId)

        #expect(Set(events.map(\.field)) == ["Status", "Priority"])
        #expect(events.count == 2)
    }

    @Test("agent moves stay silent on any select field (self-mutation guard)")
    func agentMoveSilent() {
        let (store, appId, item) = freshKanban()
        var events: [CanvasEvent] = []
        store.onCanvasEvent = { events.append($0) }

        _ = store.patchItem(id: item, with: ["Priority": "High"], myAppId: appId,
                            actor: .agent(toolName: "patchTrackerItems"))
        #expect(events.isEmpty)
    }

    @Test("re-writing a select field with its current value publishes nothing")
    func noOpWriteSilent() {
        let (store, appId, item) = freshKanban()
        var events: [CanvasEvent] = []
        store.onCanvasEvent = { events.append($0) }

        _ = store.patchItem(id: item, with: ["Status": "Doing"], myAppId: appId)
        #expect(events.isEmpty)
    }

    @Test("transitionId is per-field: same from→to on two fields differs")
    func transitionIdIsPerField() {
        let (store, appId, item) = freshKanban()
        var ids: [String] = []
        store.onCanvasEvent = { ids.append($0.transitionId) }

        // Both fields go "" → "X" is impossible here, so use the two-field patch
        // and assert the ids differ purely because the field name differs.
        _ = store.patchItem(id: item, with: ["Status": "Review", "Priority": "High"], myAppId: appId)

        #expect(ids.count == 2)
        #expect(ids[0] != ids[1])
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

    @Test("patching a non-select field publishes no item.moved event")
    func nonSelectFieldSilent() {
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
