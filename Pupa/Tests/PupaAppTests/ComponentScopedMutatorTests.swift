import Foundation
import Testing
@testable import PupaApp

/// Pins the explicit `componentId:` overloads added so the linked-item
/// popup can edit / delete items inside a *non-active* component. The
/// default kind-preference path on `MyAppStore.mutate` resolves to the
/// active component when it matches, else the first matching one — which
/// would silently misroute mutations in a MyApp that holds more than one
/// component of the same kind.
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

        let trackerA = store.addComponent(
            kind: "tracker",
            name: "A",
            iconSystemName: "book",
            myAppId: myApp.id
        )!
        store.setTracker(
            title: "A",
            fields: [FieldDef(name: "title", type: .text)],
            myAppId: myApp.id
        )
        let rowAInA = store.addItem(["title": "in-A"], myAppId: myApp.id)!

        let trackerB = store.addComponent(
            kind: "tracker",
            name: "B",
            iconSystemName: "book.closed",
            myAppId: myApp.id
        )!
        // addComponent flips active → trackerB; setTracker / addItem now
        // target trackerB.
        store.setTracker(
            title: "B",
            fields: [FieldDef(name: "title", type: .text)],
            myAppId: myApp.id
        )
        let rowAInB = store.addItem(["title": "in-B"], myAppId: myApp.id)!

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

    @Test("patchItem without componentId hits the active component")
    func patchWithoutComponentIdHitsActive() {
        let f = freshFixture()
        // Active is trackerB. Patch trackerB's row without specifying a
        // componentId. Asking by id alone would only succeed if the id is
        // found inside trackerB's items.
        let ok = f.store.patchItem(
            id: f.rowAInB,
            with: ["title": "patched-B"],
            myAppId: f.myAppId
        )
        #expect(ok)
        #expect(trackerItem(f.store, myAppId: f.myAppId, componentId: f.trackerB, itemId: f.rowAInB)?.values["title"] == "patched-B")
        // A row id from trackerA is not visible to the kind-preference
        // resolver while trackerB is active, so the no-arg patch is a
        // no-op rather than misrouting.
        let missOk = f.store.patchItem(
            id: f.rowAInA,
            with: ["title": "misrouted"],
            myAppId: f.myAppId
        )
        #expect(missOk == false)
        #expect(trackerItem(f.store, myAppId: f.myAppId, componentId: f.trackerA, itemId: f.rowAInA)?.values["title"] == "in-A")
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
