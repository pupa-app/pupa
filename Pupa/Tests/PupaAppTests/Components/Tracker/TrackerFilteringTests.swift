import Foundation
import Testing
@testable import PupaApp

/// Row selection shared by the grid and kanban tracker views: the persisted
/// select filter, the ephemeral search query, and the "Untitled #n"
/// numbering contract that depends on unfiltered positions.
@Suite("Tracker filtering")
struct TrackerFilteringTests {

    private let fields: [FieldDef] = [
        FieldDef(name: "title", type: .text),
        FieldDef(name: "notes", type: .text),
        FieldDef(name: "status", type: .select, options: ["todo", "done"]),
        FieldDef(name: "docs", type: .link),
        FieldDef(name: "cover", type: .image),
    ]

    private func items() -> [TrackerItem] {
        [
            TrackerItem(values: ["title": "Ship kanban", "notes": "needs QA",
                                 "status": "todo", "docs": "https://github.com/x",
                                 "cover": "https://cdn.example.com/a.png"]),
            TrackerItem(values: ["title": "Write docs", "notes": "architecture page",
                                 "status": "done"]),
            TrackerItem(values: ["title": "Fix flake", "status": "todo"]),
        ]
    }

    private func entries(filter: [String: String] = [:], query: String = "") -> [TrackerFiltering.Entry] {
        TrackerFiltering.visibleEntries(items: items(), fields: fields, filter: filter, query: query)
    }

    @Test("No filter and no query returns every row in order")
    func passthrough() {
        let out = entries()
        #expect(out.count == 3)
        #expect(out.map(\.positionIndex) == [0, 1, 2])
    }

    @Test("Select filter ANDs across fields and ignores case")
    func selectFilter() {
        #expect(entries(filter: ["status": "todo"]).count == 2)
        #expect(entries(filter: ["status": "TODO"]).count == 2)
        // Empty values are inert, not "match nothing".
        #expect(entries(filter: ["status": ""]).count == 3)
        #expect(entries(filter: ["status": "todo", "title": "Fix flake"]).count == 1)
    }

    @Test("Query matches title, notes and link values, case-insensitively")
    func querySearchesTextAndLinks() {
        #expect(entries(query: "kanban").map(\.item.values["title"]) == ["Ship kanban"])
        #expect(entries(query: "SHIP").count == 1)
        // Substring, not prefix.
        #expect(entries(query: "rchitect").count == 1)
        // Link field values are searchable.
        #expect(entries(query: "github.com").count == 1)
    }

    @Test("Query never matches an .image value")
    func imageValuesAreNotSearchable() {
        // Would otherwise match every row carrying a hero image URL.
        #expect(entries(query: "cdn.example.com").isEmpty)
    }

    @Test("Filter and query compose — a row must pass both")
    func filterAndQueryCompose() {
        #expect(entries(filter: ["status": "todo"], query: "docs").isEmpty)
        #expect(entries(filter: ["status": "done"], query: "docs").count == 1)
    }

    @Test("Whitespace-only query is treated as empty")
    func blankQuery() {
        #expect(entries(query: "   \n ").count == 3)
    }

    @Test("positionIndex stays the unfiltered index")
    func positionIndexSurvivesFiltering() {
        // Drives the card's "Untitled #n" fallback — it must not renumber as
        // rows drop out while the user types.
        let out = entries(query: "flake")
        #expect(out.count == 1)
        #expect(out[0].positionIndex == 2)
    }
}
