import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for the tracker grid ⇄ kanban view-mode toggle, the kanban
/// "Group by" column-field resolution, and the `setTrackerViewMode`
/// frontend tool.
@MainActor
@Suite("Tracker view mode")
struct TrackerViewModeTests {

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

    /// Regression: switching `columnField` while already in `.kanban` mode
    /// must persist the new column. The original implementation wrote
    /// `t.columnField = resolved` before the change-diff check, so the
    /// `t.columnField == resolved` comparison was trivially true and
    /// `mutate` short-circuited without persisting — leaving the kanban
    /// "Group by" dropdown silently no-op'ing on the second pick.
    @Test("Re-picking columnField while already in kanban actually persists the change")
    func columnFieldChangeWhileInKanbanPersists() {
        let (store, id) = makeStore(fields: [
            FieldDef(name: "status", type: .select, options: ["todo", "done"]),
            FieldDef(name: "priority", type: .select, options: ["low", "high"]),
        ])

        // First switch: into kanban grouping by "status".
        let first = store.setTrackerViewMode(.kanban, columnField: "status", myAppId: id)
        #expect(first?.mode == .kanban)
        #expect(first?.columnField == "status")
        #expect(tracker(store, id: id)?.columnField == "status")

        // Second switch: stay in kanban but flip to "priority". This is the
        // path the "Group by" menu drives. Must update store state, not no-op.
        let second = store.setTrackerViewMode(.kanban, columnField: "priority", myAppId: id)
        #expect(second?.mode == .kanban)
        #expect(second?.columnField == "priority")
        #expect(tracker(store, id: id)?.columnField == "priority")
    }

    /// Contract for `columnField: nil`: auto-pick the first usable select
    /// field on first entry into kanban, and preserve the user's last
    /// pick across grid → kanban → grid → kanban round-trips so toggling
    /// the view mode never silently changes the grouping.
    @Test("Omitting columnField auto-picks first select; the choice survives grid round-trips")
    func columnFieldAutoPickAndPreservation() {
        let (store, id) = makeStore(fields: [
            FieldDef(name: "status", type: .select, options: ["todo", "doing", "done"]),
            FieldDef(name: "priority", type: .select, options: ["low", "high"]),
            FieldDef(name: "notes", type: .text),
        ])

        // No explicit columnField → auto-picks "status" (first eligible select).
        let initial = store.setTrackerViewMode(.kanban, myAppId: id)
        #expect(initial?.columnField == "status")
        #expect(tracker(store, id: id)?.viewMode == .kanban)

        // User explicitly picks "priority" via the Group-by menu.
        _ = store.setTrackerViewMode(.kanban, columnField: "priority", myAppId: id)
        #expect(tracker(store, id: id)?.columnField == "priority")

        // Flip to grid — columnField is retained so the next kanban entry
        // doesn't re-pick the first option.
        _ = store.setTrackerViewMode(.grid, myAppId: id)
        #expect(tracker(store, id: id)?.viewMode == .grid)
        #expect(tracker(store, id: id)?.columnField == "priority")

        // Toolbar toggle back to kanban with no columnField hint — must
        // resume on the previously chosen "priority", not snap to "status".
        let resumed = store.setTrackerViewMode(.kanban, myAppId: id)
        #expect(resumed?.columnField == "priority")
        #expect(tracker(store, id: id)?.columnField == "priority")
    }

    /// End-to-end through the AppTools registry: the `setTrackerViewMode`
    /// frontend tool routes through `MyAppStore.setTrackerViewMode` and
    /// echoes `{ok, mode, columnField, totalItems}` to the agent. Also
    /// pins the invalid-mode rejection so the agent gets a structured
    /// error rather than a silent no-op for typos like `mode: "kaban"`.
    @Test("setTrackerViewMode tool echoes resolved state and rejects invalid mode strings")
    func setTrackerViewModeToolEcho() async throws {
        let (store, id) = makeStore(fields: [
            FieldDef(name: "status", type: .select, options: ["todo", "done"]),
        ])
        // Seed an item so totalItems is non-trivial in the echo.
        store.addItem(["status": "todo"], myAppId: id)

        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: id)

        guard let tool = registry.resolve("setTrackerViewMode") else {
            Issue.record("setTrackerViewMode not registered")
            return
        }

        // Happy path: omit columnField, expect auto-pick + populated echo.
        let okResult = try await tool.handler(.object([
            "mode": .string("kanban"),
        ]))
        let okObj = okResult.objectValue
        #expect(okObj?["ok"]?.boolValue == true)
        #expect(okObj?["mode"]?.stringValue == "kanban")
        #expect(okObj?["columnField"]?.stringValue == "status")
        #expect(okObj?["totalItems"]?.intValue == 1)
        #expect(tracker(store, id: id)?.viewMode == .kanban)

        // Invalid mode: must not flip state, must return structured error.
        let badResult = try await tool.handler(.object([
            "mode": .string("kaban"),  // typo
        ]))
        let badObj = badResult.objectValue
        #expect(badObj?["ok"]?.boolValue == false)
        #expect(badObj?["error"]?.stringValue?.contains("invalid mode") == true)
        // State is unchanged from the previous happy-path call.
        #expect(tracker(store, id: id)?.viewMode == .kanban)
        #expect(tracker(store, id: id)?.columnField == "status")
    }
}
