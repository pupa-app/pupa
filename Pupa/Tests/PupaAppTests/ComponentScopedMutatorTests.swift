import Foundation
import Testing
@testable import PupaApp

/// Pins the explicit `componentId:` overloads used so the linked-item
/// popup (and the agent tools) can edit / delete items inside a specific
/// component. The kind-routed fallback on `MyAppStore.mutate` no longer
/// consults the active/view component at all — it resolves to the first
/// component of the kind — so a no-id mutation never silently follows what
/// the user happens to be looking at.
@MainActor
@Suite("componentId-scoped mutators")
struct ComponentScopedMutatorTests {

    private struct Fixture {
        let store: MyAppStore
        let myAppId: UUID
        let trackerA: String
        let trackerB: String
        let rowAInA: UUID
        let rowAInB: UUID
    }

    /// Builds a MyApp with two tracker components, each holding a single
    /// row. Tracker A's row id and tracker B's row id are distinct, so a
    /// kind-preference patch can be observably routed by checking which
    /// component changed.
    private func freshFixture() -> Fixture {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(
            name: "T",
            iconSystemName: "list.bullet.rectangle",
            typeId: MyAppType.tracker.id
        )
        let store = MyAppStore(initial: ([myApp], myApp.id))

        // Build each tracker by explicit componentId — no-id routing is
        // deterministic-first now, not active, so setup must name its target.
        let trackerA = store.addComponent(
            kind: "tracker",
            name: "A",
            iconSystemName: "book",
            myAppId: myApp.id
        )!
        store.setTracker(
            title: "A",
            fields: [FieldDef(name: "title", type: .text)],
            myAppId: myApp.id,
            componentId: trackerA
        )
        let rowAInA = store.addItem(["title": "in-A"], myAppId: myApp.id, componentId: trackerA)!

        let trackerB = store.addComponent(
            kind: "tracker",
            name: "B",
            iconSystemName: "book.closed",
            myAppId: myApp.id
        )!
        store.setTracker(
            title: "B",
            fields: [FieldDef(name: "title", type: .text)],
            myAppId: myApp.id,
            componentId: trackerB
        )
        let rowAInB = store.addItem(["title": "in-B"], myAppId: myApp.id, componentId: trackerB)!

        return Fixture(
            store: store,
            myAppId: myApp.id,
            trackerA: trackerA,
            trackerB: trackerB,
            rowAInA: rowAInA,
            rowAInB: rowAInB
        )
    }

    private func trackerItem(
        _ store: MyAppStore,
        myAppId: UUID,
        componentId: String,
        itemId: UUID
    ) -> TrackerItem? {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }),
              let comp = myApp.components.first(where: { $0.id == componentId }),
              case .tracker(let t) = comp.body else { return nil }
        return t.items.first(where: { $0.id == itemId })
    }

    @Test("patchItem(componentId:) routes to the named tracker, not the active one")
    func patchScopedToInactiveComponent() {
        let f = freshFixture()
        // Active is trackerB (from fixture). Patch the row that lives in
        // trackerA via the explicit componentId override.
        let ok = f.store.patchItem(
            id: f.rowAInA,
            with: ["title": "patched"],
            myAppId: f.myAppId,
            componentId: f.trackerA
        )
        #expect(ok)
        #expect(trackerItem(f.store, myAppId: f.myAppId, componentId: f.trackerA, itemId: f.rowAInA)?.values["title"] == "patched")
        // Tracker B's row untouched.
        #expect(trackerItem(f.store, myAppId: f.myAppId, componentId: f.trackerB, itemId: f.rowAInB)?.values["title"] == "in-B")
    }

    @Test("patchItem without componentId ignores the active component (deterministic first)")
    func patchWithoutComponentIdIgnoresActive() {
        let f = freshFixture()
        // Focus trackerB. A no-id patch must NOT follow the view — the
        // kind-routed fallback resolves to the FIRST tracker (A) regardless.
        f.store.setActiveComponent(componentId: f.trackerB, myAppId: f.myAppId)

        // rowAInA lives in the first tracker (A) — a no-id patch reaches it
        // even though B is active, proving active is not consulted.
        let ok = f.store.patchItem(
            id: f.rowAInA,
            with: ["title": "patched"],
            myAppId: f.myAppId
        )
        #expect(ok)
        #expect(trackerItem(f.store, myAppId: f.myAppId, componentId: f.trackerA, itemId: f.rowAInA)?.values["title"] == "patched")

        // rowAInB lives in the active tracker (B), but the resolver only
        // looks at the first tracker (A), so a no-id patch can't find it —
        // a no-op, not a misroute to the active component.
        let missOk = f.store.patchItem(
            id: f.rowAInB,
            with: ["title": "misrouted"],
            myAppId: f.myAppId
        )
        #expect(missOk == false)
        #expect(trackerItem(f.store, myAppId: f.myAppId, componentId: f.trackerB, itemId: f.rowAInB)?.values["title"] == "in-B")
    }

    /// Regression: the tracker VIEW layer (add-item sheet, filter chips,
    /// kanban toggle, kanban drag-move) must pass the rendered component's
    /// id into every store mutation. Before the fix these UI paths omitted
    /// `componentId`, so on a multi-tracker myApp they silently routed to
    /// the FIRST tracker (A) instead of the tracker on screen (B) — a diary
    /// row added while viewing B landed in A, invisible. These pin the
    /// store contract the fixed views depend on: an explicit id hits that
    /// tracker and leaves the first untouched.
    @Test("addItem(componentId:) lands on the viewed (non-first) tracker, not tracker A")
    func addItemScopedToViewedTracker() {
        let f = freshFixture()
        // View shows tracker B (second, active). Sheet add must target B.
        let newId = f.store.addItem(["title": "diary row"], myAppId: f.myAppId, componentId: f.trackerB)
        #expect(newId != nil)
        // Landed in B…
        #expect(trackerItem(f.store, myAppId: f.myAppId, componentId: f.trackerB, itemId: newId!)?.values["title"] == "diary row")
        // …and NOT in A (which still holds only its seed row).
        guard let appA = f.store.myApps.first(where: { $0.id == f.myAppId }),
              let compA = appA.components.first(where: { $0.id == f.trackerA }),
              case .tracker(let tA) = compA.body else {
            Issue.record("expected tracker A"); return
        }
        #expect(tA.items.count == 1)
        #expect(tA.items.first?.values["title"] == "in-A")
    }

    @Test("setFilter(componentId:) sets the viewed tracker's filter, not tracker A's")
    func setFilterScopedToViewedTracker() {
        let f = freshFixture()
        f.store.setFilter(field: "title", value: "x", myAppId: f.myAppId, componentId: f.trackerB)
        func filterOf(_ id: String) -> [String: String]? {
            guard let app = f.store.myApps.first(where: { $0.id == f.myAppId }),
                  let comp = app.components.first(where: { $0.id == id }),
                  case .tracker(let t) = comp.body else { return nil }
            return t.filter
        }
        #expect(filterOf(f.trackerB)?["title"] == "x")
        #expect(filterOf(f.trackerA)?.isEmpty == true)
    }

    @Test("setTrackerViewMode(componentId:) flips the viewed tracker, not tracker A")
    func setViewModeScopedToViewedTracker() {
        let f = freshFixture()
        _ = f.store.setTrackerViewMode(.kanban, myAppId: f.myAppId, componentId: f.trackerB)
        func viewModeOf(_ id: String) -> TrackerViewMode? {
            guard let app = f.store.myApps.first(where: { $0.id == f.myAppId }),
                  let comp = app.components.first(where: { $0.id == id }),
                  case .tracker(let t) = comp.body else { return nil }
            return t.viewMode
        }
        #expect(viewModeOf(f.trackerB) == .kanban)
        #expect(viewModeOf(f.trackerA) == .grid)
    }

    @Test("removeItem(componentId:) removes from the named tracker and cascades correctly")
    func removeScopedToInactiveComponent() {
        let f = freshFixture()
        // Link checklist row to rowAInA so we can verify cascade ref drop
        // targets the right component.
        let checkComp = f.store.addComponent(
            kind: "checklist",
            name: "C",
            iconSystemName: "checklist",
            myAppId: f.myAppId
        )!
        let checkRow = f.store.addChecklistItem(text: "todo", myAppId: f.myAppId)!
        var patch = MyAppStore.ChecklistItemPatch()
        patch.linkedItems = [ComponentItemRef(componentId: f.trackerA, itemId: f.rowAInA)]
        _ = f.store.patchChecklistItem(id: checkRow, patch: patch, myAppId: f.myAppId)

        // Remove rowAInA explicitly via componentId override (active is
        // checklist after addComponent above).
        let ok = f.store.removeItem(id: f.rowAInA, myAppId: f.myAppId, componentId: f.trackerA)
        #expect(ok)
        #expect(trackerItem(f.store, myAppId: f.myAppId, componentId: f.trackerA, itemId: f.rowAInA) == nil)

        // Cascade should drop the checklist's ref to the now-deleted row.
        guard let myApp = f.store.myApps.first(where: { $0.id == f.myAppId }),
              let comp = myApp.components.first(where: { $0.id == checkComp }),
              case .checklist(let cl) = comp.body else {
            Issue.record("expected checklist component")
            return
        }
        #expect(cl.items.first?.linkedItems.isEmpty == true)
    }
}

/// Same view-layer routing contract as the tracker suite, extended to the
/// other kinds whose UI mutators were leaking `componentId` (checklist
/// add / toggle / remove, calendar view-mode + add-event). On a myApp with
/// two components of a kind, a UI write must land on the component on
/// screen — never silently on the first component of that kind.
@MainActor
@Suite("componentId-scoped mutators — calendar & checklist")
struct ComponentScopedMutatorOtherKindsTests {

    private func app() -> (MyAppStore, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "x", typeId: MyAppType.tracker.id)
        return (MyAppStore(initial: ([myApp], myApp.id)), myApp.id)
    }

    private func checklist(_ store: MyAppStore, myAppId: UUID, componentId: String) -> ChecklistData? {
        guard let m = store.myApps.first(where: { $0.id == myAppId }),
              let c = m.components.first(where: { $0.id == componentId }),
              case .checklist(let cl) = c.body else { return nil }
        return cl
    }

    private func calendar(_ store: MyAppStore, myAppId: UUID, componentId: String) -> CalendarData? {
        guard let m = store.myApps.first(where: { $0.id == myAppId }),
              let c = m.components.first(where: { $0.id == componentId }),
              case .calendar(let cal) = c.body else { return nil }
        return cal
    }

    @Test("checklist add / toggle / remove land on the viewed (non-first) checklist")
    func checklistScoped() {
        let (store, myAppId) = app()
        let clA = store.addComponent(kind: "checklist", name: "A", iconSystemName: "x", myAppId: myAppId)!
        let clB = store.addComponent(kind: "checklist", name: "B", iconSystemName: "x", myAppId: myAppId)!

        // Add to B (second, viewed). Must not touch A.
        let row = store.addChecklistItem(text: "task", myAppId: myAppId, componentId: clB)!
        #expect(checklist(store, myAppId: myAppId, componentId: clB)?.items.count == 1)
        #expect(checklist(store, myAppId: myAppId, componentId: clA)?.items.isEmpty == true)

        // Toggle done on B's row.
        _ = store.setChecklistItemDone(id: row, done: true, myAppId: myAppId, componentId: clB)
        #expect(checklist(store, myAppId: myAppId, componentId: clB)?.items.first?.done == true)

        // Remove from B.
        _ = store.removeChecklistItem(id: row, myAppId: myAppId, componentId: clB)
        #expect(checklist(store, myAppId: myAppId, componentId: clB)?.items.isEmpty == true)
    }

    @Test("calendar view-mode + add-event land on the viewed (non-first) calendar")
    func calendarScoped() {
        let (store, myAppId) = app()
        let calA = store.addComponent(kind: "calendar", name: "A", iconSystemName: "x", myAppId: myAppId)!
        let calB = store.addComponent(kind: "calendar", name: "B", iconSystemName: "x", myAppId: myAppId)!

        // Flip B to month view — A stays on its default.
        _ = store.setCalendarViewMode(.month, myAppId: myAppId, componentId: calB)
        #expect(calendar(store, myAppId: myAppId, componentId: calB)?.viewMode == .month)
        #expect(calendar(store, myAppId: myAppId, componentId: calA)?.viewMode != .month)

        // Add an event to B — must not land in A.
        let ev = CalendarEvent(id: UUID(), title: "sync", start: "2026-07-11T10:00:00Z")
        _ = store.addCalendarEvent(ev, myAppId: myAppId, componentId: calB)
        #expect(calendar(store, myAppId: myAppId, componentId: calB)?.events.count == 1)
        #expect(calendar(store, myAppId: myAppId, componentId: calA)?.events.isEmpty == true)
    }
}
