import Foundation
import Testing
@testable import PupaApp

/// Kanban lane bucketing. The load-bearing invariant is that the lane set
/// depends only on the column field's options — never on which rows match —
/// so filtering or searching narrows cards without reflowing the board.
@Suite("Tracker kanban lanes")
struct TrackerKanbanLanesTests {

    private let column = FieldDef(name: "status", type: .select, options: ["todo", "doing", "done"])

    private let fields: [FieldDef] = [
        FieldDef(name: "title", type: .text),
        FieldDef(name: "status", type: .select, options: ["todo", "doing", "done"]),
    ]

    private func items() -> [TrackerItem] {
        [
            TrackerItem(values: ["title": "alpha", "status": "todo"]),
            TrackerItem(values: ["title": "beta", "status": "done"]),
            TrackerItem(values: ["title": "gamma"]),
            TrackerItem(values: ["title": "delta", "status": "  "]),
            TrackerItem(values: ["title": "epsilon", "status": "archived"]),
        ]
    }

    private func lanes(filter: [String: String] = [:], query: String = "") -> [TrackerFiltering.LaneBucket] {
        let entries = TrackerFiltering.visibleEntries(
            items: items(), fields: fields, filter: filter, query: query
        )
        return TrackerFiltering.lanes(entries: entries, column: column)
    }

    @Test("Every option lane plus (Unset) is returned, in declaration order")
    func laneShape() {
        let out = lanes()
        #expect(out.map(\.id) == ["todo", "doing", "done", TrackerFiltering.unsetLaneId])
        #expect(out.last?.title == "(Unset)")
        #expect(out.last?.laneValue == "")
    }

    @Test("Empty, blank and unrecognized column values land in (Unset)")
    func unsetBucket() {
        let unset = lanes().last
        #expect(unset?.entries.count == 3)
        #expect(unset?.entries.map(\.item.values["title"]) == ["gamma", "delta", "epsilon"])
    }

    @Test("A filter narrows entries but never removes a lane")
    func filterKeepsAllLanes() {
        let out = lanes(filter: ["status": "todo"])
        #expect(out.count == 4)
        #expect(out.first(where: { $0.id == "todo" })?.entries.count == 1)
        #expect(out.first(where: { $0.id == "done" })?.entries.isEmpty == true)
    }

    @Test("A query narrows entries but never removes a lane")
    func queryKeepsAllLanes() {
        let out = lanes(query: "alpha")
        #expect(out.count == 4)
        #expect(out.map(\.entries.count) == [1, 0, 0, 0])
    }

    @Test("Lane entries keep their unfiltered positionIndex")
    func positionIndexPreserved() {
        let done = lanes().first(where: { $0.id == "done" })
        #expect(done?.entries.first?.positionIndex == 1)
    }
}
