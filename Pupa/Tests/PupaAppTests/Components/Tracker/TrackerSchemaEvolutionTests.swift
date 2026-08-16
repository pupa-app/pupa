import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for the tracker's non-destructive schema evolution:
/// `addTrackerField` / `renameTrackerField` / `reorderTrackerFields` /
/// `hideTrackerField` / `showTrackerField`, the stable item-id model, and
/// the legacy-shape decoder migration. Every test pins the invariant that
/// item data must survive a schema mutation — once items exist on a tracker,
/// no field-list operation should ever wipe or rewrite their values.
@MainActor
@Suite("Tracker schema evolution")
struct TrackerSchemaEvolutionTests {

    private func makeStore(fields: [FieldDef]) -> (store: MyAppStore, id: UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.setTracker(title: "Test", fields: fields, myAppId: myApp.id)
        return (store, myApp.id)
    }

    private func tracker(_ store: MyAppStore, id: UUID) -> TrackerData? {
        guard let myApp = store.myApps.first(where: { $0.id == id }) else { return nil }
        if case .tracker(let t) = myApp.canvas { return t }
        return nil
    }

    // MARK: - addField

    @Test("addField appends without mutating items")
    func addFieldDoesNotTouchItems() {
        let (store, id) = makeStore(fields: [FieldDef(name: "title", type: .text)])
        _ = store.addItem(["title": "first"], myAppId: id)
        _ = store.addItem(["title": "second"], myAppId: id)
        let beforeIds = tracker(store, id: id)?.items.map(\.id) ?? []

        let err = store.addField(FieldDef(name: "category", type: .text), myAppId: id)

        #expect(err == nil)
        let t = tracker(store, id: id)
        #expect(t?.fields.map(\.name) == ["title", "category"])
        #expect(t?.items.count == 2)
        #expect(t?.items.map(\.id) == beforeIds, "item ids must be unchanged")
        #expect(t?.items[0].values["title"] == "first")
        #expect(t?.items[0].values["category"] == nil, "new field has no value on existing items")
        #expect(t?.items[1].values["title"] == "second")
    }

    @Test("addField rejects a duplicate name")
    func addFieldRejectsDuplicate() {
        let (store, id) = makeStore(fields: [FieldDef(name: "title", type: .text)])
        let err = store.addField(FieldDef(name: "title", type: .number), myAppId: id)
        #expect(err == .duplicateName)
        #expect(tracker(store, id: id)?.fields.count == 1)
    }

    // MARK: - renameField

    @Test("renameField re-keys item values, filter, and columnField")
    func renameFieldCascadesEverywhere() {
        let (store, id) = makeStore(fields: [
            FieldDef(name: "status", type: .select, options: ["todo", "done"]),
            FieldDef(name: "note", type: .text),
        ])
        _ = store.addItem(["status": "todo", "note": "a"], myAppId: id)
        _ = store.addItem(["status": "done", "note": "b"], myAppId: id)
        _ = store.addItem(["note": "c"], myAppId: id) // no status value
        _ = store.setTrackerViewMode(.kanban, columnField: "status", myAppId: id)
        store.setFilter(field: "status", value: "todo", myAppId: id)

        let result = store.renameField(from: "status", to: "stage", myAppId: id)

        switch result {
        case .failure(let err):
            Issue.record("rename failed: \(err)")
        case .success(let payload):
            #expect(payload.migratedItems == 2, "only items that had the 'status' key get re-keyed")
            #expect(payload.remappedFilter == true)
            #expect(payload.remappedColumnField == true)
        }
        let t = tracker(store, id: id)
        #expect(t?.fields.map(\.name) == ["stage", "note"])
        #expect(t?.items[0].values["stage"] == "todo")
        #expect(t?.items[0].values["status"] == nil)
        #expect(t?.items[1].values["stage"] == "done")
        #expect(t?.items[2].values["stage"] == nil, "items that had no status value stay absent")
        #expect(t?.items[2].values["note"] == "c")
        #expect(t?.filter["stage"] == "todo")
        #expect(t?.filter["status"] == nil)
        #expect(t?.columnField == "stage")
    }

    @Test("renameField rejects when destination already exists")
    func renameFieldRejectsCollision() {
        let (store, id) = makeStore(fields: [
            FieldDef(name: "a", type: .text),
            FieldDef(name: "b", type: .text),
        ])
        _ = store.addItem(["a": "1", "b": "2"], myAppId: id)
        let result = store.renameField(from: "a", to: "b", myAppId: id)
        if case .failure(let err) = result {
            #expect(err == .duplicateName)
        } else {
            Issue.record("expected duplicateName rejection")
        }
        // No mutation should have happened.
        let t = tracker(store, id: id)
        #expect(t?.fields.map(\.name) == ["a", "b"])
        #expect(t?.items[0].values["a"] == "1")
        #expect(t?.items[0].values["b"] == "2")
    }

    // MARK: - reorderFields

    @Test("reorderFields shuffles fields without touching items; rejects non-permutations")
    func reorderFieldsIsPermutationStrict() {
        let (store, id) = makeStore(fields: [
            FieldDef(name: "a", type: .text),
            FieldDef(name: "b", type: .text),
            FieldDef(name: "c", type: .text),
        ])
        _ = store.addItem(["a": "1", "b": "2", "c": "3"], myAppId: id)
        let beforeIds = tracker(store, id: id)?.items.map(\.id) ?? []

        // Happy path — a valid permutation.
        let ok = store.reorderFields(["c", "a", "b"], myAppId: id)
        #expect(ok == nil)
        let t = tracker(store, id: id)
        #expect(t?.fields.map(\.name) == ["c", "a", "b"])
        #expect(t?.items.map(\.id) == beforeIds)
        #expect(t?.items[0].values == ["a": "1", "b": "2", "c": "3"])

        // Length mismatch.
        #expect(store.reorderFields(["a", "b"], myAppId: id) == .invalidOrder)
        // Unknown name.
        #expect(store.reorderFields(["a", "b", "z"], myAppId: id) == .invalidOrder)
        // Duplicate entries.
        #expect(store.reorderFields(["a", "a", "b"], myAppId: id) == .invalidOrder)
        // Field list unchanged after each rejection.
        #expect(tracker(store, id: id)?.fields.map(\.name) == ["c", "a", "b"])
    }

    // MARK: - hide / show

    @Test("hideField preserves item values; show restores; hide drops matching filter")
    func hideShowPreservesData() {
        let (store, id) = makeStore(fields: [
            FieldDef(name: "title", type: .text),
            FieldDef(name: "notes", type: .text),
        ])
        _ = store.addItem(["title": "x", "notes": "draft"], myAppId: id)
        store.setFilter(field: "notes", value: "draft", myAppId: id)

        switch store.setFieldHidden(name: "notes", hidden: true, myAppId: id) {
        case .failure(let err):
            Issue.record("hide failed: \(err)")
        case .success(let r):
            #expect(r.hidden == true)
            #expect(r.droppedFilterValue == "draft", "active filter on a hidden field must be cleared")
        }
        var t = tracker(store, id: id)
        #expect(t?.fields.first(where: { $0.name == "notes" })?.hidden == true)
        #expect(t?.visibleFields.map(\.name) == ["title"])
        #expect(t?.items[0].values["notes"] == "draft", "hidden field's item value survives on disk")
        #expect(t?.filter["notes"] == nil)

        // Un-hide: column reappears with original value intact.
        _ = store.setFieldHidden(name: "notes", hidden: false, myAppId: id)
        t = tracker(store, id: id)
        #expect(t?.visibleFields.map(\.name) == ["title", "notes"])
        #expect(t?.items[0].values["notes"] == "draft")
    }

    @Test("Hidden column field downgrades kanban to no-usable-column")
    func hiddenColumnFieldFallsBack() {
        let (store, id) = makeStore(fields: [
            FieldDef(name: "stage", type: .select, options: ["todo", "done"]),
        ])
        _ = store.addItem(["stage": "todo"], myAppId: id)
        _ = store.setTrackerViewMode(.kanban, columnField: "stage", myAppId: id)
        #expect(tracker(store, id: id)?.viewMode == .kanban)
        #expect(tracker(store, id: id)?.columnField == "stage")

        _ = store.setFieldHidden(name: "stage", hidden: true, myAppId: id)
        // columnField stays so unhide restores grouping, but the resolved
        // column is now invalid — the view falls back to the empty hint and
        // setTrackerViewMode auto-pick skips hidden fields.
        let resumed = store.setTrackerViewMode(.kanban, myAppId: id)
        #expect(resumed?.columnField == nil, "no visible select field → no column")
    }

    // MARK: - id-keyed item ops

    @Test("addTrackerItems echoes stable ids usable by patchTrackerItems")
    func itemIdEchoRoundTrip() async throws {
        let (store, id) = makeStore(fields: [FieldDef(name: "title", type: .text)])
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: id)

        guard let add = registry.resolve("addTrackerItems"),
              let patch = registry.resolve("patchTrackerItems"),
              let remove = registry.resolve("removeTrackerItems") else {
            Issue.record("expected tools not registered"); return
        }
        let addResult = try await add.handler(.object([
            "items": .array([.object(["title": .string("first")])]),
        ]))
        let firstId = addResult.objectValue?["ids"]?.arrayValue?.first?.stringValue
        #expect(firstId.flatMap(UUID.init(uuidString:)) != nil, "addTrackerItems must echo a UUID id")

        // Add a second item so a stale "index 0" target would be ambiguous.
        _ = try await add.handler(.object([
            "items": .array([.object(["title": .string("second")])]),
        ]))

        // Patch by id: still finds the original row even after another item exists.
        let patched = try await patch.handler(.object([
            "patches": .array([
                .object([
                    "id": .string(firstId ?? ""),
                    "patch": .object(["title": .string("first-edited")]),
                ]),
            ]),
        ]))
        #expect(patched.objectValue?["ok"]?.boolValue == true)
        let firstPatchResult = patched.objectValue?["results"]?.arrayValue?.first
        #expect(firstPatchResult?.objectValue?["item"]?.objectValue?["title"]?.stringValue == "first-edited")

        // Remove by id leaves the second row untouched.
        let removed = try await remove.handler(.object([
            "targets": .array([.object(["id": .string(firstId ?? "")])]),
        ]))
        #expect(removed.objectValue?["ok"]?.boolValue == true)
        let t = tracker(store, id: id)
        #expect(t?.items.count == 1)
        #expect(t?.items[0].values["title"] == "second")
    }

    @Test("patchItem(id:) survives a reorderFields between operations")
    func idLookupSurvivesReorder() {
        let (store, id) = makeStore(fields: [
            FieldDef(name: "a", type: .text),
            FieldDef(name: "b", type: .text),
        ])
        guard let itemId = store.addItem(["a": "1", "b": "2"], myAppId: id) else {
            Issue.record("addItem returned no id"); return
        }
        _ = store.reorderFields(["b", "a"], myAppId: id)
        let ok = store.patchItem(id: itemId, with: ["a": "1-edited"], myAppId: id)
        #expect(ok == true)
        let t = tracker(store, id: id)
        #expect(t?.items.first(where: { $0.id == itemId })?.values["a"] == "1-edited")
    }

    @Test("FieldDef.hidden round-trips through Codable, defaults to nil when absent")
    func fieldHiddenCodable() throws {
        let json = """
        {"name": "x", "type": "text"}
        """.data(using: .utf8)!
        let f1 = try JSONDecoder().decode(FieldDef.self, from: json)
        #expect(f1.hidden == nil)

        let hidden = FieldDef(name: "y", type: .text, hidden: true)
        let encoded = try JSONEncoder().encode(hidden)
        let f2 = try JSONDecoder().decode(FieldDef.self, from: encoded)
        #expect(f2.hidden == true)
    }

    @Test("TrackerData.shrinkCards defaults to false on pre-shrink blobs and round-trips")
    func shrinkCardsCodable() throws {
        let legacy = """
        {"title": "T", "fields": [{"name": "x", "type": "text"}], "items": []}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(TrackerData.self, from: legacy).shrinkCards == false)

        let shrunk = TrackerData(title: "T", fields: [FieldDef(name: "x", type: .text)], shrinkCards: true)
        let round = try JSONDecoder().decode(TrackerData.self, from: JSONEncoder().encode(shrunk))
        #expect(round.shrinkCards == true)

        // A blob written by a newer build still decodes here.
        let future = """
        {"title": "T", "fields": [], "items": [], "shrinkCards": true, "somethingNew": 3}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(TrackerData.self, from: future).shrinkCards == true)
    }
}
