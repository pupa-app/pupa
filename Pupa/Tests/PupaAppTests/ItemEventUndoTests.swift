import Foundation
import Testing
@testable import PupaApp

@MainActor
@Suite("ItemEvent undo system")
struct ItemEventUndoTests {

    // MARK: - Helpers

    private func assertSuccess(_ result: Result<Void, MyAppStore.UndoError>,
                                _ comment: String = "Expected .success") {
        if case .failure(let err) = result {
            #expect(Bool(false), "\(comment): got \(err)")
        }
    }

    private func freshTrackerStore() -> (MyAppStore, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.setTracker(title: "Test", fields: [FieldDef(name: "title", type: .text)], myAppId: myApp.id)
        return (store, myApp.id)
    }

    private func freshCalendarStore() -> (MyAppStore, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "C", iconSystemName: "calendar", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.addComponent(kind: "calendar", name: "Cal", iconSystemName: "calendar", myAppId: myApp.id)
        return (store, myApp.id)
    }

    private func freshChecklistStore() -> (MyAppStore, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "L", iconSystemName: "checklist", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.addComponent(kind: "checklist", name: "List", iconSystemName: "checklist", myAppId: myApp.id)
        return (store, myApp.id)
    }

    private func trackerItems(_ store: MyAppStore, myAppId: UUID) -> [TrackerItem]? {
        store.myApps.first(where: { $0.id == myAppId })?
            .components.compactMap { if case .tracker(let t) = $0.body { return t } else { return nil } }
            .first?.items
    }

    private func calendarEvents(_ store: MyAppStore, myAppId: UUID) -> [CalendarEvent]? {
        store.myApps.first(where: { $0.id == myAppId })?
            .components.compactMap { if case .calendar(let c) = $0.body { return c } else { return nil } }
            .first?.events
    }

    private func checklistItems(_ store: MyAppStore, myAppId: UUID) -> [ChecklistItem]? {
        store.myApps.first(where: { $0.id == myAppId })?
            .components.compactMap { if case .checklist(let cl) = $0.body { return cl } else { return nil } }
            .first?.items
    }

    // MARK: - Tracker round-trips

    @Test("tracker add → undo removes the row")
    func trackerAddUndo() throws {
        let (store, id) = freshTrackerStore()
        let itemId = try #require(store.addItem(["title": "hello"], myAppId: id))
        #expect(trackerItems(store, myAppId: id)?.count == 1)

        let event = try #require(store.itemEventLog.events(forMyApp: id).last)
        #expect(event.kind == .added)
        #expect(event.inverse() != nil)

        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        #expect(trackerItems(store, myAppId: id)?.count == 0)
        #expect(store.itemEventLog.all.first(where: { $0.id == event.id })?.undone == true)

        // The undo itself is recorded as an isUndo event
        let undoEvent = try #require(store.itemEventLog.events(forMyApp: id).last)
        #expect(undoEvent.isUndo == true)
        #expect(undoEvent.kind == .removed)
        _ = itemId
    }

    @Test("tracker remove → undo reinserts at original index")
    func trackerRemoveUndo() throws {
        let (store, id) = freshTrackerStore()
        _ = store.addItem(["title": "A"], myAppId: id)
        let bId = try #require(store.addItem(["title": "B"], myAppId: id))
        _ = store.addItem(["title": "C"], myAppId: id)
        #expect(trackerItems(store, myAppId: id)?.count == 3)

        _ = store.removeItem(id: bId, myAppId: id)
        #expect(trackerItems(store, myAppId: id)?.count == 2)
        #expect(trackerItems(store, myAppId: id)?[0].values["title"] == "A")
        #expect(trackerItems(store, myAppId: id)?[1].values["title"] == "C")

        let event = try #require(
            store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .removed && !$0.isUndo })
        )
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        let items = try #require(trackerItems(store, myAppId: id))
        #expect(items.count == 3)
        // B should be back at index 1
        #expect(items[1].id == bId)
        #expect(items[1].values["title"] == "B")
    }

    @Test("tracker patch → undo restores prior values")
    func trackerPatchUndo() throws {
        let (store, id) = freshTrackerStore()
        let itemId = try #require(store.addItem(["title": "original"], myAppId: id))
        _ = store.patchItem(id: itemId, with: ["title": "patched"], myAppId: id)

        let event = try #require(
            store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .patched && !$0.isUndo })
        )
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        let items = try #require(trackerItems(store, myAppId: id))
        #expect(items.first(where: { $0.id == itemId })?.values["title"] == "original")
    }

    // MARK: - Calendar round-trips

    @Test("calendar add → undo removes the event")
    func calendarAddUndo() throws {
        let (store, id) = freshCalendarStore()
        let ev = CalendarEvent(title: "Meeting", start: "2026-06-01T10:00:00Z")
        _ = store.addCalendarEvent(ev, myAppId: id)
        #expect(calendarEvents(store, myAppId: id)?.count == 1)

        let event = try #require(store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .added && !$0.isUndo }))
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        #expect(calendarEvents(store, myAppId: id)?.count == 0)
    }

    @Test("calendar remove → undo reinserts at original index")
    func calendarRemoveUndo() throws {
        let (store, id) = freshCalendarStore()
        let ev1 = CalendarEvent(title: "First", start: "2026-06-01T09:00:00Z")
        let ev2 = CalendarEvent(title: "Second", start: "2026-06-01T10:00:00Z")
        _ = store.addCalendarEvent(ev1, myAppId: id)
        _ = store.addCalendarEvent(ev2, myAppId: id)

        _ = store.removeCalendarEvent(id: ev1.id, myAppId: id)
        #expect(calendarEvents(store, myAppId: id)?.count == 1)

        let event = try #require(
            store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .removed && !$0.isUndo })
        )
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        let events = try #require(calendarEvents(store, myAppId: id))
        #expect(events.count == 2)
        #expect(events[0].id == ev1.id)
    }

    @Test("calendar patch → undo restores prior fields")
    func calendarPatchUndo() throws {
        let (store, id) = freshCalendarStore()
        let ev = CalendarEvent(title: "Original", start: "2026-06-01T10:00:00Z")
        _ = store.addCalendarEvent(ev, myAppId: id)

        let patch = MyAppStore.CalendarEventPatch(title: "Patched")
        _ = store.patchCalendarEvent(id: ev.id, patch: patch, myAppId: id)

        let event = try #require(
            store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .patched && !$0.isUndo })
        )
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        #expect(calendarEvents(store, myAppId: id)?.first?.title == "Original")
    }

    // MARK: - Checklist round-trips

    @Test("checklist add → undo removes the item")
    func checklistAddUndo() throws {
        let (store, id) = freshChecklistStore()
        _ = store.addChecklistItem(text: "buy milk", myAppId: id)
        #expect(checklistItems(store, myAppId: id)?.count == 1)

        let event = try #require(
            store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .added && !$0.isUndo })
        )
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        #expect(checklistItems(store, myAppId: id)?.count == 0)
    }

    @Test("checklist remove → undo reinserts at original index")
    func checklistRemoveUndo() throws {
        let (store, id) = freshChecklistStore()
        let aId = try #require(store.addChecklistItem(text: "A", myAppId: id))
        _ = store.addChecklistItem(text: "B", myAppId: id)
        _ = store.addChecklistItem(text: "C", myAppId: id)

        _ = store.removeChecklistItem(id: aId, myAppId: id)
        #expect(checklistItems(store, myAppId: id)?.count == 2)

        let event = try #require(
            store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .removed && !$0.isUndo })
        )
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        let items = try #require(checklistItems(store, myAppId: id))
        #expect(items.count == 3)
        #expect(items[0].id == aId)
        #expect(items[0].text == "A")
    }

    @Test("checklist patch → undo restores prior text and done")
    func checklistPatchUndo() throws {
        let (store, id) = freshChecklistStore()
        let itemId = try #require(store.addChecklistItem(text: "original", done: false, myAppId: id))
        let patch = MyAppStore.ChecklistItemPatch(text: "changed", done: true)
        _ = store.patchChecklistItem(id: itemId, patch: patch, myAppId: id)

        let event = try #require(
            store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .patched && !$0.isUndo })
        )
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        let item = try #require(checklistItems(store, myAppId: id)?.first(where: { $0.id == itemId }))
        #expect(item.text == "original")
        #expect(item.done == false)
    }

    // MARK: - Link / unlink round-trips

    @Test("link → undo removes the link")
    func linkUndo() throws {
        let (store, id) = freshTrackerStore()
        store.addComponent(kind: "checklist", name: "Tasks", iconSystemName: "checklist", myAppId: id)
        let trackerItemId = try #require(store.addItem(["title": "row"], myAppId: id))
        let clItemId = try #require(store.addChecklistItem(text: "task", myAppId: id))

        guard let trackerCompId = store.myApps.first(where: { $0.id == id })?
            .components.first(where: { $0.kindString == "tracker" })?.id,
              let clCompId = store.myApps.first(where: { $0.id == id })?
            .components.first(where: { $0.kindString == "checklist" })?.id
        else { #expect(Bool(false), "Components not found"); return }

        _ = store.linkItems(sourceComponentId: trackerCompId, sourceItemId: trackerItemId,
                            targetComponentId: clCompId, targetItemId: clItemId, myAppId: id)

        let trackerRow = try #require(
            trackerItems(store, myAppId: id)?.first(where: { $0.id == trackerItemId })
        )
        #expect(trackerRow.linkedItems.count == 1)

        let event = try #require(
            store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .linked })
        )
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        let after = try #require(
            trackerItems(store, myAppId: id)?.first(where: { $0.id == trackerItemId })
        )
        #expect(after.linkedItems.isEmpty)
    }

    @Test("unlink → undo restores the link")
    func unlinkUndo() throws {
        let (store, id) = freshTrackerStore()
        store.addComponent(kind: "checklist", name: "Tasks", iconSystemName: "checklist", myAppId: id)
        let trackerItemId = try #require(store.addItem(["title": "row"], myAppId: id))
        let clItemId = try #require(store.addChecklistItem(text: "task", myAppId: id))

        guard let trackerCompId = store.myApps.first(where: { $0.id == id })?
            .components.first(where: { $0.kindString == "tracker" })?.id,
              let clCompId = store.myApps.first(where: { $0.id == id })?
            .components.first(where: { $0.kindString == "checklist" })?.id
        else { #expect(Bool(false), "Components not found"); return }

        _ = store.linkItems(sourceComponentId: trackerCompId, sourceItemId: trackerItemId,
                            targetComponentId: clCompId, targetItemId: clItemId, myAppId: id)
        _ = store.unlinkItems(sourceComponentId: trackerCompId, sourceItemId: trackerItemId,
                              targetComponentId: clCompId, targetItemId: clItemId, myAppId: id)

        let event = try #require(
            store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .unlinked })
        )
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        let after = try #require(
            trackerItems(store, myAppId: id)?.first(where: { $0.id == trackerItemId })
        )
        #expect(after.linkedItems.count == 1)
    }

    // MARK: - Component round-trips

    @Test("component add → undo removes the component")
    func componentAddUndo() throws {
        let (store, id) = freshTrackerStore()
        let compId = try #require(
            store.addComponent(kind: "checklist", name: "Tasks", iconSystemName: "checklist", myAppId: id)
        )
        let initialCount = store.myApps.first(where: { $0.id == id })!.components.count

        let event = try #require(
            store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .added && $0.componentId == compId })
        )
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        let afterCount = store.myApps.first(where: { $0.id == id })?.components.count ?? 0
        #expect(afterCount == initialCount - 1)
    }

    @Test("component remove → undo reinserts at original index")
    func componentRemoveUndo() throws {
        let (store, id) = freshTrackerStore()
        let compId = try #require(
            store.addComponent(kind: "checklist", name: "Tasks", iconSystemName: "checklist", myAppId: id)
        )
        let beforeCount = store.myApps.first(where: { $0.id == id })!.components.count
        let compIdx = store.myApps.first(where: { $0.id == id })!.components.firstIndex(where: { $0.id == compId })!

        _ = store.removeComponent(componentId: compId, myAppId: id)
        #expect(store.myApps.first(where: { $0.id == id })?.components.count == beforeCount - 1)

        let event = try #require(
            store.itemEventLog.events(forMyApp: id).last(where: { $0.kind == .removed && $0.componentId == compId })
        )
        let result = store.undo(eventId: event.id)
        assertSuccess(result)
        let components = try #require(store.myApps.first(where: { $0.id == id })?.components)
        #expect(components.count == beforeCount)
        #expect(components[compIdx].id == compId)
    }

    // MARK: - Error cases

    @Test("double-undo returns alreadyUndone")
    func doubleUndo() throws {
        let (store, id) = freshTrackerStore()
        _ = store.addItem(["title": "x"], myAppId: id)
        let event = try #require(store.itemEventLog.events(forMyApp: id).last)
        _ = store.undo(eventId: event.id)
        let second = store.undo(eventId: event.id)
        if case .failure(let err) = second {
            #expect(err == .alreadyUndone)
        } else {
            #expect(Bool(false), "Expected .alreadyUndone")
        }
    }

    @Test("undo of an isUndo event returns alreadyUndone")
    func undoOfUndoEvent() throws {
        let (store, id) = freshTrackerStore()
        _ = store.addItem(["title": "x"], myAppId: id)
        let event = try #require(store.itemEventLog.events(forMyApp: id).last)
        _ = store.undo(eventId: event.id)
        // The undo event itself
        let undoEvent = try #require(store.itemEventLog.events(forMyApp: id).last)
        #expect(undoEvent.isUndo == true)
        let result = store.undo(eventId: undoEvent.id)
        if case .failure(let err) = result {
            #expect(err == .alreadyUndone)
        } else {
            #expect(Bool(false), "Expected .alreadyUndone for undo-of-undo")
        }
    }

    @Test("legacy empty-payload event returns notReversible without crash")
    func legacyEmptyPayload() {
        let (store, id) = freshTrackerStore()
        let legacyEvent = ItemEvent(
            myAppId: id,
            componentId: "tracker-1",
            kind: .removed,
            payload: Data(),
            actor: .user
        )
        store.appendEventForTesting(legacyEvent)
        let result = store.undo(eventId: legacyEvent.id)
        if case .failure(let err) = result {
            #expect(err == .notReversible)
        } else {
            #expect(Bool(false), "Expected .notReversible for empty payload")
        }
    }

    @Test("undo of unknown eventId returns eventNotFound")
    func unknownEventId() {
        let (store, _) = freshTrackerStore()
        let result = store.undo(eventId: UUID())
        if case .failure(let err) = result {
            #expect(err == .eventNotFound)
        } else {
            #expect(Bool(false), "Expected .eventNotFound")
        }
    }

    @Test("out-of-order undo still applies correctly")
    func outOfOrderUndo() throws {
        let (store, id) = freshTrackerStore()
        let id1 = try #require(store.addItem(["title": "first"], myAppId: id))
        _ = store.addItem(["title": "second"], myAppId: id)
        _ = store.patchItem(id: id1, with: ["title": "first-patched"], myAppId: id)

        // Undo the original addItem even though a later patch happened
        let addEvent = try #require(
            store.itemEventLog.events(forMyApp: id).first(where: { $0.kind == .added && $0.itemId == id1 })
        )
        let result = store.undo(eventId: addEvent.id)
        // Should succeed (out-of-order allowed in v1)
        assertSuccess(result)
        #expect(trackerItems(store, myAppId: id)?.first(where: { $0.id == id1 }) == nil)
    }

    // MARK: - Snapshot persistence

    @Test("ItemEventLog round-trips through Codable")
    func eventLogCodable() throws {
        var log = ItemEventLog()
        let myAppId = UUID()
        let inverse = ItemEventInverse.trackerAdded(itemId: UUID())
        let payload = try JSONEncoder().encode(inverse)
        log.append(ItemEvent(myAppId: myAppId, componentId: "tracker-1", kind: .added,
                             payload: payload, actor: .user, itemId: UUID()))
        log.append(ItemEvent(myAppId: myAppId, componentId: "tracker-1", kind: .removed,
                             actor: .agent(toolName: "removeTrackerItems")))

        let data = try JSONEncoder().encode(log)
        var decoded = try JSONDecoder().decode(ItemEventLog.self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded.all[0].kind == .added)
        #expect(decoded.all[0].payload == payload)
        #expect(decoded.all[1].actor == .agent(toolName: "removeTrackerItems"))

        // markUndone
        decoded.markUndone(id: decoded.all[0].id)
        #expect(decoded.all[0].undone == true)
    }

    @Test("prune drops events older than TTL and enforces cap")
    func pruneDropsOldEvents() {
        var log = ItemEventLog(cap: 5)
        let myAppId = UUID()
        let old = Date(timeIntervalSinceNow: -(31 * 24 * 60 * 60))  // 31 days ago
        let recent = Date()

        // 3 old events
        for i in 0..<3 {
            log.append(ItemEvent(id: UUID(), timestamp: old, myAppId: myAppId,
                                 componentId: "tracker-\(i)", kind: .added, actor: .user))
        }
        // 3 recent events
        for i in 3..<6 {
            log.append(ItemEvent(id: UUID(), timestamp: recent, myAppId: myAppId,
                                 componentId: "tracker-\(i)", kind: .added, actor: .user))
        }
        #expect(log.count == 5)  // cap=5 already evicted oldest 1

        log.prune(now: Date(), ttl: ItemEventLog.defaultTTL)
        // Only 3 recent events remain (all old ones past TTL)
        #expect(log.count == 3)
        #expect(log.all.allSatisfy { $0.timestamp >= recent.addingTimeInterval(-1) })
    }

    @Test("prune enforces cap after TTL sweep")
    func pruneEnforcesCap() {
        var log = ItemEventLog(cap: 3)
        let myAppId = UUID()
        for i in 0..<5 {
            log.append(ItemEvent(myAppId: myAppId, componentId: "t-\(i)", kind: .added, actor: .user))
        }
        // Cap of 3 already applied; only last 3 remain
        log.prune()
        #expect(log.count == 3)
    }

    // MARK: - ItemEventInverse Codable

    @Test("ItemEventInverse round-trips for all cases")
    func inverseAllCases() throws {
        let item = TrackerItem(values: ["title": "x"])
        let calEvent = CalendarEvent(title: "Meet", start: "2026-06-01T10:00:00Z")
        let clItem = ChecklistItem(text: "task")
        let ref = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        let ref2 = ComponentItemRef(componentId: "checklist-1", itemId: UUID())
        let comp = Component(id: "checklist-1", name: "Tasks", iconSystemName: "checklist",
                             body: .empty)

        let cases: [ItemEventInverse] = [
            .trackerAdded(itemId: UUID()),
            .trackerRemoved(snapshot: item, index: 2),
            .trackerPatched(snapshot: item),
            .calendarAdded(itemId: UUID()),
            .calendarRemoved(snapshot: calEvent, index: 0),
            .calendarPatched(snapshot: calEvent),
            .checklistAdded(itemId: UUID()),
            .checklistRemoved(snapshot: clItem, index: 1),
            .checklistPatched(snapshot: clItem),
            .linked(source: ref, target: ref2),
            .unlinked(source: ref, target: ref2),
            .componentAdded(componentId: "checklist-1"),
            .componentRemoved(snapshot: comp, index: 1),
        ]

        for inv in cases {
            let data = try JSONEncoder().encode(inv)
            // Decode and re-encode to verify the JSON is structurally round-trippable
            let decoded = try JSONDecoder().decode(ItemEventInverse.self, from: data)
            // Verify re-encode doesn't throw and produces valid JSON
            let reEncoded = try JSONEncoder().encode(decoded)
            // Verify re-decoded is also valid
            _ = try JSONDecoder().decode(ItemEventInverse.self, from: reEncoded)
        }
    }
}
