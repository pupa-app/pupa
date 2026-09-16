import Foundation
import Testing
@testable import PupaApp

/// Tests for the generic `linkItems` / `unlinkItems` mutators that
/// replaced the four kind-specific link/unlink pairs in project
/// `0.0.41`. Pins:
///
/// - Symmetric N-to-N coverage: any source kind to any target kind.
/// - Self-component links allowed (different rows in the same
///   component); literal self-ref (`source == target`) rejected.
/// - Idempotent on duplicate add / missing remove.
/// - Cross-cascade: removing any referenced item drops the matching
///   pill from every link-bearing kind in the MiniApp.
/// - Structured `LinkMutationError` for missing source / target.
@MainActor
@Suite("Universal item-to-item linking")
struct UniversalLinkingTests {

    /// Builds a MiniApp pre-populated with one tracker (with two rows),
    /// one calendar (with two events), and one checklist (with two
    /// rows). Returns the store, MiniApp id, and the component ids so
    /// tests can build refs without re-querying.
    private struct Fixture {
        let store: MiniAppStore
        let miniAppId: UUID
        let trackerCompId: String
        let calendarCompId: String
        let checklistCompId: String
        let trackerRowA: UUID
        let trackerRowB: UUID
        let eventA: UUID
        let eventB: UUID
        let checklistRowA: UUID
        let checklistRowB: UUID
    }

    private func freshFixture() -> Fixture {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApp = MiniApp(
            name: "T",
            iconSystemName: "list.bullet.rectangle",
            typeId: MiniAppType.tracker.id
        )
        let store = MiniAppStore(initial: ([miniApp], miniApp.id))

        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", miniAppId: miniApp.id)
        store.setTracker(
            title: "Books",
            fields: [FieldDef(name: "title", type: .text)],
            miniAppId: miniApp.id
        )
        let trackerRowA = store.addItem(["title": "Hail Mary"], miniAppId: miniApp.id)!
        let trackerRowB = store.addItem(["title": "Project Sleep"], miniAppId: miniApp.id)!

        store.addComponent(kind: "calendar", name: "Cal", iconSystemName: "calendar", miniAppId: miniApp.id)
        store.setCalendar(title: "Cal", miniAppId: miniApp.id)
        let eventA = store.addCalendarEvent(
            CalendarEvent(title: "Read time", start: "2026-06-01T10:00:00Z"),
            miniAppId: miniApp.id
        )!
        let eventB = store.addCalendarEvent(
            CalendarEvent(title: "Coffee", start: "2026-06-02T15:00:00Z"),
            miniAppId: miniApp.id
        )!

        store.addComponent(kind: "checklist", name: "Errands", iconSystemName: "checklist", miniAppId: miniApp.id)
        let checklistRowA = store.addChecklistItem(text: "shopping", miniAppId: miniApp.id)!
        let checklistRowB = store.addChecklistItem(text: "pack", miniAppId: miniApp.id)!

        let comps = store.miniApps[0].components
        return Fixture(
            store: store,
            miniAppId: miniApp.id,
            trackerCompId: comps.first(where: { $0.kindString == "tracker" })!.id,
            calendarCompId: comps.first(where: { $0.kindString == "calendar" })!.id,
            checklistCompId: comps.first(where: { $0.kindString == "checklist" })!.id,
            trackerRowA: trackerRowA,
            trackerRowB: trackerRowB,
            eventA: eventA,
            eventB: eventB,
            checklistRowA: checklistRowA,
            checklistRowB: checklistRowB
        )
    }

    private func trackerItem(_ store: MiniAppStore, miniAppId: UUID, componentId: String, itemId: UUID) -> TrackerItem? {
        guard let miniApp = store.miniApps.first(where: { $0.id == miniAppId }),
              let comp = miniApp.components.first(where: { $0.id == componentId }),
              case .tracker(let t) = comp.body else { return nil }
        return t.items.first(where: { $0.id == itemId })
    }

    private func calendarEvent(_ store: MiniAppStore, miniAppId: UUID, componentId: String, itemId: UUID) -> CalendarEvent? {
        guard let miniApp = store.miniApps.first(where: { $0.id == miniAppId }),
              let comp = miniApp.components.first(where: { $0.id == componentId }),
              case .calendar(let cal) = comp.body else { return nil }
        return cal.events.first(where: { $0.id == itemId })
    }

    private func checklistItem(_ store: MiniAppStore, miniAppId: UUID, componentId: String, itemId: UUID) -> ChecklistItem? {
        guard let miniApp = store.miniApps.first(where: { $0.id == miniAppId }),
              let comp = miniApp.components.first(where: { $0.id == componentId }),
              case .checklist(let cl) = comp.body else { return nil }
        return cl.items.first(where: { $0.id == itemId })
    }

    // MARK: - Symmetric N-to-N coverage

    @Test("Tracker row → calendar event link lands on the tracker row's linkedItems")
    func trackerToCalendar() {
        let f = freshFixture()
        let outcome = f.store.linkItems(
            sourceComponentId: f.trackerCompId,
            sourceItemId: f.trackerRowA,
            targetComponentId: f.calendarCompId,
            targetItemId: f.eventA,
            miniAppId: f.miniAppId
        )
        guard case .success(let count) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(count == 1)
        let row = trackerItem(f.store, miniAppId: f.miniAppId, componentId: f.trackerCompId, itemId: f.trackerRowA)
        #expect(row?.linkedItems.first?.componentId == f.calendarCompId)
        #expect(row?.linkedItems.first?.itemId == f.eventA)
    }

    @Test("Calendar event → checklist row link lands on the event's linkedItems")
    func calendarToChecklist() {
        let f = freshFixture()
        let outcome = f.store.linkItems(
            sourceComponentId: f.calendarCompId,
            sourceItemId: f.eventA,
            targetComponentId: f.checklistCompId,
            targetItemId: f.checklistRowA,
            miniAppId: f.miniAppId
        )
        guard case .success(let count) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(count == 1)
        let event = calendarEvent(f.store, miniAppId: f.miniAppId, componentId: f.calendarCompId, itemId: f.eventA)
        #expect(event?.linkedItems.first?.componentId == f.checklistCompId)
        #expect(event?.linkedItems.first?.itemId == f.checklistRowA)
    }

    @Test("Checklist row → tracker row link lands on the checklist row's linkedItems")
    func checklistToTracker() {
        let f = freshFixture()
        let outcome = f.store.linkItems(
            sourceComponentId: f.checklistCompId,
            sourceItemId: f.checklistRowA,
            targetComponentId: f.trackerCompId,
            targetItemId: f.trackerRowA,
            miniAppId: f.miniAppId
        )
        guard case .success(let count) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(count == 1)
        let row = checklistItem(f.store, miniAppId: f.miniAppId, componentId: f.checklistCompId, itemId: f.checklistRowA)
        #expect(row?.linkedItems.first?.componentId == f.trackerCompId)
        #expect(row?.linkedItems.first?.itemId == f.trackerRowA)
    }

    // MARK: - Self-component links

    @Test("Self-component link (checklist row → another row in same checklist) is allowed")
    func selfComponentChecklistAllowed() {
        let f = freshFixture()
        let outcome = f.store.linkItems(
            sourceComponentId: f.checklistCompId,
            sourceItemId: f.checklistRowA,
            targetComponentId: f.checklistCompId,
            targetItemId: f.checklistRowB,
            miniAppId: f.miniAppId
        )
        guard case .success(let count) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(count == 1)
        let row = checklistItem(f.store, miniAppId: f.miniAppId, componentId: f.checklistCompId, itemId: f.checklistRowA)
        #expect(row?.linkedItems.first?.itemId == f.checklistRowB)
    }

    @Test("Self-component link between two tracker rows in same tracker is allowed")
    func selfComponentTrackerAllowed() {
        let f = freshFixture()
        let outcome = f.store.linkItems(
            sourceComponentId: f.trackerCompId,
            sourceItemId: f.trackerRowA,
            targetComponentId: f.trackerCompId,
            targetItemId: f.trackerRowB,
            miniAppId: f.miniAppId
        )
        guard case .success = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        let row = trackerItem(f.store, miniAppId: f.miniAppId, componentId: f.trackerCompId, itemId: f.trackerRowA)
        #expect(row?.linkedItems.first?.itemId == f.trackerRowB)
    }

    @Test("True self-reference (source == target) is rejected with .selfReference")
    func trueSelfReferenceRejected() {
        let f = freshFixture()
        let outcome = f.store.linkItems(
            sourceComponentId: f.checklistCompId,
            sourceItemId: f.checklistRowA,
            targetComponentId: f.checklistCompId,
            targetItemId: f.checklistRowA,
            miniAppId: f.miniAppId
        )
        if case .failure(let err) = outcome {
            #expect(err == .selfReference)
        } else {
            Issue.record("expected .failure(.selfReference), got \(outcome)")
        }
        let row = checklistItem(f.store, miniAppId: f.miniAppId, componentId: f.checklistCompId, itemId: f.checklistRowA)
        #expect(row?.linkedItems.isEmpty == true, "no ref must be added on rejection")
    }

    // MARK: - Idempotence + missing inputs

    @Test("Duplicate linkItems calls no-op and report the same count")
    func duplicateLinkIsIdempotent() {
        let f = freshFixture()
        _ = f.store.linkItems(
            sourceComponentId: f.checklistCompId,
            sourceItemId: f.checklistRowA,
            targetComponentId: f.trackerCompId,
            targetItemId: f.trackerRowA,
            miniAppId: f.miniAppId
        )
        let second = f.store.linkItems(
            sourceComponentId: f.checklistCompId,
            sourceItemId: f.checklistRowA,
            targetComponentId: f.trackerCompId,
            targetItemId: f.trackerRowA,
            miniAppId: f.miniAppId
        )
        guard case .success(let count) = second else {
            Issue.record("expected success on duplicate, got \(second)")
            return
        }
        #expect(count == 1, "idempotent on duplicate, count stays at 1")
    }

    @Test("Unknown source / target each return distinct LinkMutationError values")
    func unknownInputsReportSpecificErrors() {
        let f = freshFixture()
        let unknownSrc = f.store.linkItems(
            sourceComponentId: "tracker-999",
            sourceItemId: UUID(),
            targetComponentId: f.trackerCompId,
            targetItemId: f.trackerRowA,
            miniAppId: f.miniAppId
        )
        if case .failure(let err) = unknownSrc { #expect(err == .unknownSource) }

        let unknownSrcItem = f.store.linkItems(
            sourceComponentId: f.trackerCompId,
            sourceItemId: UUID(),
            targetComponentId: f.trackerCompId,
            targetItemId: f.trackerRowB,
            miniAppId: f.miniAppId
        )
        if case .failure(let err) = unknownSrcItem { #expect(err == .unknownSourceItem) }

        let unknownTarget = f.store.linkItems(
            sourceComponentId: f.checklistCompId,
            sourceItemId: f.checklistRowA,
            targetComponentId: "tracker-999",
            targetItemId: UUID(),
            miniAppId: f.miniAppId
        )
        if case .failure(let err) = unknownTarget { #expect(err == .unknownTarget) }

        let unknownTargetItem = f.store.linkItems(
            sourceComponentId: f.checklistCompId,
            sourceItemId: f.checklistRowA,
            targetComponentId: f.trackerCompId,
            targetItemId: UUID(),
            miniAppId: f.miniAppId
        )
        if case .failure(let err) = unknownTargetItem { #expect(err == .unknownTargetItem) }
    }

    @Test("unlinkItems is idempotent — removing an absent ref succeeds with unchanged count")
    func unlinkAbsentIsIdempotent() {
        let f = freshFixture()
        // Nothing's linked yet — removing should still succeed.
        let outcome = f.store.unlinkItems(
            sourceComponentId: f.checklistCompId,
            sourceItemId: f.checklistRowA,
            targetComponentId: f.trackerCompId,
            targetItemId: f.trackerRowA,
            miniAppId: f.miniAppId
        )
        guard case .success(let count) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(count == 0)
    }

    // MARK: - Cross-cascade

    @Test("Removing a tracker row drops the ref from a tracker, a calendar, AND a checklist source")
    func cascadeFromTrackerRow() {
        let f = freshFixture()
        // Three sources, each pointing at the same tracker row.
        _ = f.store.linkItems(
            sourceComponentId: f.trackerCompId,
            sourceItemId: f.trackerRowB,
            targetComponentId: f.trackerCompId,
            targetItemId: f.trackerRowA,
            miniAppId: f.miniAppId
        )
        _ = f.store.linkItems(
            sourceComponentId: f.calendarCompId,
            sourceItemId: f.eventA,
            targetComponentId: f.trackerCompId,
            targetItemId: f.trackerRowA,
            miniAppId: f.miniAppId
        )
        _ = f.store.linkItems(
            sourceComponentId: f.checklistCompId,
            sourceItemId: f.checklistRowA,
            targetComponentId: f.trackerCompId,
            targetItemId: f.trackerRowA,
            miniAppId: f.miniAppId
        )

        _ = f.store.removeItem(id: f.trackerRowA, miniAppId: f.miniAppId)

        #expect(trackerItem(f.store, miniAppId: f.miniAppId, componentId: f.trackerCompId, itemId: f.trackerRowB)?.linkedItems.isEmpty == true)
        #expect(calendarEvent(f.store, miniAppId: f.miniAppId, componentId: f.calendarCompId, itemId: f.eventA)?.linkedItems.isEmpty == true)
        #expect(checklistItem(f.store, miniAppId: f.miniAppId, componentId: f.checklistCompId, itemId: f.checklistRowA)?.linkedItems.isEmpty == true)
    }

    @Test("Removing a checklist row drops the ref from a tracker source (PR 1 only swept calendars / checklists)")
    func cascadeFromChecklistRow() {
        let f = freshFixture()
        _ = f.store.linkItems(
            sourceComponentId: f.trackerCompId,
            sourceItemId: f.trackerRowA,
            targetComponentId: f.checklistCompId,
            targetItemId: f.checklistRowA,
            miniAppId: f.miniAppId
        )
        #expect(trackerItem(f.store, miniAppId: f.miniAppId, componentId: f.trackerCompId, itemId: f.trackerRowA)?.linkedItems.count == 1)

        _ = f.store.removeChecklistItem(id: f.checklistRowA, miniAppId: f.miniAppId)

        #expect(trackerItem(f.store, miniAppId: f.miniAppId, componentId: f.trackerCompId, itemId: f.trackerRowA)?.linkedItems.isEmpty == true,
                "tracker source must lose the pill pointing at the deleted checklist row")
    }

    // MARK: - Persistence backward-compat

    @Test("Pre-0.0.41 tracker JSON (no linkedItems field on items) decodes with [] linkedItems")
    func trackerBackwardCompat() throws {
        let itemId = UUID()
        let json = """
        {
          "kind": "tracker",
          "data": {
            "title": "Legacy",
            "fields": [{"name": "title", "type": "text"}],
            "items": [
              { "id": "\(itemId.uuidString)", "values": {"title": "old row"} }
            ],
            "filter": {}
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CanvasApp.self, from: json)
        guard case .tracker(let t) = decoded else {
            Issue.record("decoded as \(decoded.kindString) — expected tracker")
            return
        }
        #expect(t.items.first?.id == itemId)
        #expect(t.items.first?.linkedItems.isEmpty == true)
    }
}
