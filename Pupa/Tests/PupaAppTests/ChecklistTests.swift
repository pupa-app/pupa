import Foundation
import Testing
@testable import PupaApp

/// Tests for the checklist component: per-item mutators, the SwiftUI-
/// backing `setChecklistItemDone` idempotent setter, the editor patch
/// shape, persistence round-trip + backward-compat decoding, and the
/// linking surface (link a checklist row to a tracker item or calendar
/// event, plus the cascade-on-target-removal sweep).
@MainActor
@Suite("Checklist component")
struct ChecklistTests {

    private func freshStore() -> (MyAppStore, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(
            name: "T",
            iconSystemName: "list.bullet.rectangle",
            typeId: MyAppType.tracker.id
        )
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.addComponent(
            kind: "checklist",
            name: "Errands",
            iconSystemName: "checklist",
            myAppId: myApp.id
        )
        return (store, myApp.id)
    }

    private func checklist(_ store: MyAppStore, id: UUID) -> ChecklistData? {
        guard let myApp = store.myApps.first(where: { $0.id == id }) else { return nil }
        for comp in myApp.components {
            if case .checklist(let cl) = comp.body { return cl }
        }
        return nil
    }

    // MARK: - Basic mutators

    @Test("addChecklistItem returns a stable id and appends")
    func addChecklistItem() {
        let (store, id) = freshStore()
        let one = store.addChecklistItem(text: "milk", myAppId: id)
        let two = store.addChecklistItem(text: "eggs", done: true, myAppId: id)

        #expect(one != nil)
        #expect(two != nil)
        #expect(one != two)
        let cl = checklist(store, id: id)
        #expect(cl?.items.count == 2)
        #expect(cl?.items[0].text == "milk")
        #expect(cl?.items[0].done == false)
        #expect(cl?.items[1].text == "eggs")
        #expect(cl?.items[1].done == true)
    }

    @Test("toggleChecklistItem flips done and returns the new value")
    func toggle() {
        let (store, id) = freshStore()
        let itemId = store.addChecklistItem(text: "bread", myAppId: id)!

        let after1 = store.toggleChecklistItem(id: itemId, myAppId: id)
        #expect(after1 == true)
        #expect(checklist(store, id: id)?.items.first?.done == true)

        let after2 = store.toggleChecklistItem(id: itemId, myAppId: id)
        #expect(after2 == false)
        #expect(checklist(store, id: id)?.items.first?.done == false)

        // Unknown id is a clean nil — never crashes.
        let missing = store.toggleChecklistItem(id: UUID(), myAppId: id)
        #expect(missing == nil)
    }

    @Test("setChecklistItemDone is idempotent — sets to a target value, no-op when already there")
    func setDoneIdempotent() {
        let (store, id) = freshStore()
        let itemId = store.addChecklistItem(text: "bread", myAppId: id)!

        let firstSet = store.setChecklistItemDone(id: itemId, done: true, myAppId: id)
        #expect(firstSet == true)
        let alreadyTrue = store.setChecklistItemDone(id: itemId, done: true, myAppId: id)
        #expect(alreadyTrue == false, "setting to current value should report no change")
        #expect(checklist(store, id: id)?.items.first?.done == true)
    }

    @Test("patchChecklistItem merges text + done + linkedItems")
    func patchMerges() {
        let (store, id) = freshStore()
        let itemId = store.addChecklistItem(text: "old", myAppId: id)!

        var patch = MyAppStore.ChecklistItemPatch()
        patch.text = "new"
        patch.done = true
        _ = store.patchChecklistItem(id: itemId, patch: patch, myAppId: id)

        let item = checklist(store, id: id)?.items.first
        #expect(item?.text == "new")
        #expect(item?.done == true)

        // Patching just one field leaves the others.
        var patch2 = MyAppStore.ChecklistItemPatch()
        patch2.text = "newer"
        _ = store.patchChecklistItem(id: itemId, patch: patch2, myAppId: id)
        let item2 = checklist(store, id: id)?.items.first
        #expect(item2?.text == "newer")
        #expect(item2?.done == true, "done was not in patch — must stay true")
    }

    @Test("patchChecklistItem with linkedItems replaces the list and de-dupes")
    func patchLinkedItemsReplaces() {
        let (store, id) = freshStore()
        let itemId = store.addChecklistItem(text: "ref me", myAppId: id)!

        let refA = TrackerItemRef(componentId: "tracker-1", itemId: UUID())
        let refB = TrackerItemRef(componentId: "tracker-1", itemId: UUID())

        var patch = MyAppStore.ChecklistItemPatch()
        patch.linkedItems = [refA, refB, refA]
        _ = store.patchChecklistItem(id: itemId, patch: patch, myAppId: id)

        let after = checklist(store, id: id)?.items.first
        #expect(after?.linkedItems == [refA, refB], "duplicates dropped, order preserved")
    }

    @Test("removeChecklistItem deletes by id and reports the removed row")
    func remove() {
        let (store, id) = freshStore()
        let a = store.addChecklistItem(text: "a", myAppId: id)!
        _ = store.addChecklistItem(text: "b", myAppId: id)

        let removed = store.removeChecklistItem(id: a, myAppId: id)
        #expect(removed?.text == "a")
        #expect(checklist(store, id: id)?.items.count == 1)
        #expect(checklist(store, id: id)?.items.first?.text == "b")
    }

    @Test("setChecklist is destructive — wipes items and replaces with the new list")
    func setIsDestructive() {
        let (store, id) = freshStore()
        _ = store.addChecklistItem(text: "old", myAppId: id)

        store.setChecklist(
            title: "Fresh",
            items: [ChecklistItem(text: "new1"), ChecklistItem(text: "new2", done: true)],
            myAppId: id
        )

        let cl = checklist(store, id: id)
        #expect(cl?.title == "Fresh")
        #expect(cl?.items.map(\.text) == ["new1", "new2"])
        #expect(cl?.items.map(\.done) == [false, true])
    }

    // MARK: - Linking surface

    // Linking is now exercised through the generic `linkItems` /
    // `unlinkItems` mutators in `UniversalLinkingTests`. The few checklist-
    // specific cascade scenarios are mirrored there alongside tracker and
    // self-component coverage.

    // MARK: - Resolver dispatch

    @Test("displayNameForRefTarget dispatches to tracker / calendar / checklist resolvers")
    func resolverDispatchesOnKind() {
        let (store, id) = freshStore()
        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: id)
        store.setTracker(title: "Books", fields: [FieldDef(name: "title", type: .text)], myAppId: id)
        let trackerItemId = store.addItem(["title": "Hail Mary"], myAppId: id)!
        let trackerComponentId = store.myApps[0].components.first(where: {
            if case .tracker = $0.body { return true }
            return false
        })!.id

        store.addComponent(kind: "calendar", name: "Cal", iconSystemName: "calendar", myAppId: id)
        store.setCalendar(title: "Cal", myAppId: id)
        let eventId = store.addCalendarEvent(
            CalendarEvent(title: "Coffee at 10", start: "2026-06-01T10:00:00Z"),
            myAppId: id
        )!
        let calComponentId = store.myApps[0].components.first(where: {
            if case .calendar = $0.body { return true }
            return false
        })!.id

        let checklistItemId = store.addChecklistItem(text: "shopping", myAppId: id)!
        let checklistComponentId = store.myApps[0].components.first(where: {
            if case .checklist = $0.body { return true }
            return false
        })!.id

        #expect(store.displayNameForRefTarget(
            componentId: trackerComponentId,
            itemId: trackerItemId,
            myAppId: id
        ) == "Hail Mary")
        #expect(store.displayNameForRefTarget(
            componentId: calComponentId,
            itemId: eventId,
            myAppId: id
        ) == "Coffee at 10")
        #expect(store.displayNameForRefTarget(
            componentId: checklistComponentId,
            itemId: checklistItemId,
            myAppId: id
        ) == "shopping")
        // Unknown component / item → nil (pill renders "(deleted)").
        #expect(store.displayNameForRefTarget(
            componentId: "tracker-999",
            itemId: UUID(),
            myAppId: id
        ) == nil)
    }

    // MARK: - Persistence

    @Test("Round-trip Codable encoding preserves all checklist fields including linkedItems")
    func roundTripCodable() throws {
        let original = ChecklistData(
            title: "Roundtrip",
            items: [
                ChecklistItem(text: "alpha", done: false),
                ChecklistItem(
                    text: "beta",
                    done: true,
                    linkedItems: [TrackerItemRef(componentId: "tracker-1", itemId: UUID())]
                ),
            ]
        )

        let data = try JSONEncoder().encode(CanvasApp.checklist(original))
        let decoded = try JSONDecoder().decode(CanvasApp.self, from: data)

        guard case .checklist(let restored) = decoded else {
            Issue.record("decoded as \(decoded.kindString) — expected checklist")
            return
        }
        #expect(restored.title == original.title)
        #expect(restored.items.count == 2)
        #expect(restored.items[0].text == "alpha")
        #expect(restored.items[1].text == "beta")
        #expect(restored.items[1].done == true)
        #expect(restored.items[1].linkedItems.count == 1)
        #expect(restored.items[0].linkedItems.isEmpty)
    }

    @Test("Pre-link checklist JSON (no linkedItems field) decodes with [] linkedItems")
    func backwardCompatDecode() throws {
        // Mirrors how on-disk MyApps from a hypothetical earlier checklist
        // version (no linkedItems field) would decode under the current
        // model. `decodeIfPresent → ?? []` keeps them clean.
        let id = UUID()
        let json = """
        {
          "kind": "checklist",
          "data": {
            "title": "Legacy",
            "items": [
              { "id": "\(id.uuidString)", "text": "old item", "done": false }
            ]
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CanvasApp.self, from: json)
        guard case .checklist(let cl) = decoded else {
            Issue.record("decoded as \(decoded.kindString) — expected checklist")
            return
        }
        #expect(cl.title == "Legacy")
        #expect(cl.items.count == 1)
        #expect(cl.items[0].id == id)
        #expect(cl.items[0].text == "old item")
        #expect(cl.items[0].linkedItems.isEmpty)
    }
}
