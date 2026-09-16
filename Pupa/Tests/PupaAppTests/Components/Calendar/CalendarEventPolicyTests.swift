import Foundation
import Testing
import AGUIKit
@testable import PupaApp

@MainActor
@Suite("CalendarEvent — Phase 3 migration")
struct CalendarEventPolicyTests {

    private func makeStore() -> (store: MiniAppStore, id: UUID) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApp = MiniApp(name: "C", iconSystemName: "calendar", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([miniApp], miniApp.id))
        store.setCalendar(title: "Test", miniAppId: miniApp.id)
        return (store, miniApp.id)
    }

    private func makeEvent(title: String = "Meeting", start: String = "2026-05-22T10:00:00Z") -> CalendarEvent {
        CalendarEvent(title: title, start: start)
    }

    // MARK: - CalendarEvent: Item conformance

    @Test("CalendarEvent.kind is 'calendar'")
    func calendarEventKind() {
        #expect(CalendarEvent.kind == "calendar")
    }

    @Test("CalendarEvent.schemaVersion defaults to 1")
    func calendarEventSchemaVersion() {
        let event = makeEvent()
        #expect(event.schemaVersion == 1)
    }

    @Test("CalendarEvent encodes schemaVersion: 1 on encode")
    func schemaVersionWrittenOnEncode() throws {
        let event = makeEvent()
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["schemaVersion"] as? Int == 1)
    }

    @Test("CalendarEvent decodes from blob without schemaVersion (backward-compat)")
    func decodesLegacyBlobWithoutSchemaVersion() throws {
        let json = """
        {"id": "00000000-0000-0000-0000-000000000001",
         "title": "Old meeting",
         "start": "2026-01-01T09:00:00Z",
         "linkedItems": []}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CalendarEvent.self, from: json)
        #expect(event.title == "Old meeting")
        #expect(event.schemaVersion == 1)
        let reEncoded = try JSONEncoder().encode(event)
        let re = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
        #expect(re?["schemaVersion"] as? Int == 1)
    }

    @Test("CalendarEvent decodes from blob without linkedItems (backward-compat)")
    func decodesLegacyBlobWithoutLinkedItems() throws {
        let json = """
        {"id": "00000000-0000-0000-0000-000000000002",
         "title": "Sprint review",
         "start": "2026-05-01T14:00:00Z"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CalendarEvent.self, from: json)
        #expect(event.linkedItems.isEmpty)
    }

    @Test("CalendarEvent.displayName returns title")
    func displayNameIsTitle() {
        let event = makeEvent(title: "Team standup")
        #expect(event.displayName == "Team standup")
    }

    @Test("CalendarEvent.displayName returns dash for blank title")
    func displayNameFallsBackToDash() {
        let event = makeEvent(title: "   ")
        #expect(event.displayName == "–")
    }

    @Test("deduplicateLinkedItems removes exact duplicates on CalendarEvent")
    func calendarEventDedup() {
        let ref = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        var event = makeEvent()
        event.linkedItems = [ref, ref, ref]
        event.deduplicateLinkedItems()
        #expect(event.linkedItems.count == 1)
    }

    // MARK: - CalendarEventPolicy

    @Test("CalendarEventPolicy is registered after registerBuiltins")
    func policyRegistered() {
        MiniAppTypeRegistry.shared.registerBuiltins()
        #expect(ItemPolicyRegistry.shared.isRegistered(forKind: "calendar"))
    }

    @Test("CalendarEventPolicy.canLinkTo allows tracker / calendar / checklist")
    func canLinkToAllowed() {
        let policy = CalendarEventPolicy()
        #expect(policy.canLinkTo(targetKind: "tracker"))
        #expect(policy.canLinkTo(targetKind: "calendar"))
        #expect(policy.canLinkTo(targetKind: "checklist"))
    }

    @Test("CalendarEventPolicy.canLinkTo blocks slack and empty")
    func canLinkToBlocked() {
        let policy = CalendarEventPolicy()
        #expect(!policy.canLinkTo(targetKind: "slack"))
        #expect(!policy.canLinkTo(targetKind: "empty"))
        #expect(!policy.canLinkTo(targetKind: "unknown"))
    }

    @Test("CalendarEventPolicy.validate passes for valid event")
    func validateValid() {
        let policy = CalendarEventPolicy()
        let event = makeEvent()
        #expect(policy.validate(event).isEmpty)
    }

    @Test("CalendarEventPolicy.validate rejects empty title")
    func validateEmptyTitle() {
        let policy = CalendarEventPolicy()
        let event = makeEvent(title: "")
        let errors = policy.validate(event)
        #expect(errors.contains(where: { $0.field == "title" }))
    }

    @Test("CalendarEventPolicy.validate rejects blank title")
    func validateBlankTitle() {
        let policy = CalendarEventPolicy()
        let event = makeEvent(title: "   ")
        let errors = policy.validate(event)
        #expect(errors.contains(where: { $0.field == "title" }))
    }

    @Test("CalendarEventPolicy.validate rejects invalid start")
    func validateInvalidStart() {
        let policy = CalendarEventPolicy()
        let event = makeEvent(start: "not-a-date")
        let errors = policy.validate(event)
        #expect(errors.contains(where: { $0.field == "start" }))
    }

    @Test("CalendarEventPolicy.validate accepts various ISO-8601 formats")
    func validateISO8601Variants() {
        let policy = CalendarEventPolicy()
        let formats = [
            "2026-05-22T10:00:00Z",
            "2026-05-22T10:00:00+02:00",
            "2026-05-22T10:00:00.000Z",
        ]
        for start in formats {
            let event = makeEvent(start: start)
            #expect(policy.validate(event).isEmpty, "expected no errors for start=\(start)")
        }
    }

    // MARK: - patchCalendarEvent uses deduplicateLinkedItems

    @Test("patchCalendarEvent deduplicates linkedItems via Item protocol method")
    func patchDeduplicatesLinkedItems() {
        let (store, id) = makeStore()
        let event = makeEvent()
        let eventId = store.addCalendarEvent(event, miniAppId: id)!
        let ref = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        let patch = MiniAppStore.CalendarEventPatch(linkedItems: [ref, ref, ref])
        let after = store.patchCalendarEvent(id: eventId, patch: patch, miniAppId: id)
        #expect(after?.linkedItems.count == 1)
    }

    // MARK: - Event log emission

    @Test("addCalendarEvent emits .added event with .user actor by default")
    func addEventEmitsUserEvent() {
        let (store, id) = makeStore()
        _ = store.addCalendarEvent(makeEvent(), miniAppId: id)
        let events = store.itemEventLog.events(forMiniApp: id)
        #expect(events.count == 1)
        #expect(events[0].kind == .added)
        #expect(events[0].actor == .user)
    }

    @Test("addCalendarEvent emits .added event with .agent actor when passed")
    func addEventEmitsAgentEvent() {
        let (store, id) = makeStore()
        _ = store.addCalendarEvent(makeEvent(), miniAppId: id, actor: .agent(toolName: "addCalendarEvent"))
        let events = store.itemEventLog.events(forMiniApp: id)
        #expect(events.count == 1)
        #expect(events[0].kind == .added)
        #expect(events[0].actor == .agent(toolName: "addCalendarEvent"))
    }

    @Test("removeCalendarEvent emits .removed event")
    func removeEventEmitsEvent() {
        let (store, id) = makeStore()
        let eventId = store.addCalendarEvent(makeEvent(), miniAppId: id, actor: .agent(toolName: "addCalendarEvent"))!
        _ = store.removeCalendarEvent(id: eventId, miniAppId: id, actor: .agent(toolName: "removeCalendarEvent"))
        let events = store.itemEventLog.events(forMiniApp: id)
        let kinds = events.map(\.kind)
        #expect(kinds.contains(.added))
        #expect(kinds.contains(.removed))
        #expect(events.last?.actor == .agent(toolName: "removeCalendarEvent"))
    }

    @Test("patchCalendarEvent emits .patched event")
    func patchEventEmitsEvent() {
        let (store, id) = makeStore()
        let eventId = store.addCalendarEvent(makeEvent(), miniAppId: id, actor: .agent(toolName: "addCalendarEvent"))!
        let patch = MiniAppStore.CalendarEventPatch(title: "Updated")
        _ = store.patchCalendarEvent(id: eventId, patch: patch, miniAppId: id, actor: .agent(toolName: "patchCalendarEvent"))
        let events = store.itemEventLog.events(forMiniApp: id)
        #expect(events.last?.kind == .patched)
        #expect(events.last?.actor == .agent(toolName: "patchCalendarEvent"))
    }

    @Test("calendar events are scoped per miniApp — two miniApps don't mix")
    func eventsPerMiniApp() {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let a = MiniApp(name: "A", iconSystemName: "calendar", typeId: MiniAppType.tracker.id)
        let b = MiniApp(name: "B", iconSystemName: "calendar", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([a, b], a.id))
        store.setCalendar(title: "A", miniAppId: a.id)
        store.setCalendar(title: "B", miniAppId: b.id)
        _ = store.addCalendarEvent(makeEvent(title: "from A"), miniAppId: a.id)
        _ = store.addCalendarEvent(makeEvent(title: "from B"), miniAppId: b.id)
        _ = store.addCalendarEvent(makeEvent(title: "from A again"), miniAppId: a.id)
        #expect(store.itemEventLog.events(forMiniApp: a.id).count == 2)
        #expect(store.itemEventLog.events(forMiniApp: b.id).count == 1)
    }
}
