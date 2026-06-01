import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for the thin canvas summary shipped in the `Live canvas state`
/// context entry: a per-component enumeration of `id`, `name`, `kind`,
/// `itemCount`, and the LLM-authored `summary` slot. Schema and items
/// are deliberately NOT in the summary — fetched via the discovery
/// tools (`listTrackerItems`, `getTrackerItem`, …).
@MainActor
@Suite("Canvas summary")
struct CanvasSummaryTests {

    private func makeMyApp() -> MyApp {
        MyAppTypeRegistry.shared.registerBuiltins()
        return MyApp(name: "T", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
    }

    @Test("Tracker summary exposes id / name / kind / itemCount only — no schema, no preview")
    func trackerSummaryShape() {
        var myApp = makeMyApp()
        let items = (1...5).map { i in TrackerItem(values: ["title": "Row \(i)"]) }
        myApp.components = [
            Component(
                id: "tracker-1",
                name: "Things",
                iconSystemName: "list.bullet",
                body: .tracker(TrackerData(title: "Things", fields: [FieldDef(name: "title", type: .text)], items: items)),
                summary: "Stuff to do"
            )
        ]
        myApp.activeComponentId = "tracker-1"

        let summary = CanvasSummary.build(myApp: myApp)
        #expect(summary.activeComponentId == "tracker-1")
        #expect(summary.components.count == 1)
        let comp = summary.components[0]
        #expect(comp.id == "tracker-1")
        #expect(comp.name == "Things")
        #expect(comp.kind == "tracker")
        #expect(comp.itemCount == 5)
        #expect(comp.summary == "Stuff to do")
    }

    @Test("summary is always present in the JSON output — even when nil, encoded as null so the slot is visible")
    func summaryAlwaysEmitted() throws {
        var myApp = makeMyApp()
        myApp.components = [
            Component(
                id: "tracker-1",
                name: "Empty",
                iconSystemName: "list.bullet",
                body: .tracker(TrackerData(title: "Empty", fields: [], items: []))
            )
        ]
        let json = CanvasSummary.build(myApp: myApp).toJSONString()
        // Sorted-keys output, so the summary key sits in alphabetical position.
        #expect(json.contains("\"summary\":null"))
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let comps = parsed?["components"] as? [[String: Any]]
        #expect(comps?.first?.keys.contains("summary") == true)
    }

    @Test("itemCount tracks the right collection per kind")
    func itemCountPerKind() {
        var myApp = makeMyApp()
        myApp.components = [
            Component(
                id: "tracker-1", name: "T", iconSystemName: "list.bullet",
                body: .tracker(TrackerData(title: "T", fields: [], items: (1...3).map { _ in TrackerItem(values: [:]) }))
            ),
            Component(
                id: "calendar-1", name: "C", iconSystemName: "calendar",
                body: .calendar(CalendarData(title: "C", events: (1...2).map { i in
                    CalendarEvent(title: "e\(i)", start: "2026-05-15T0\(i):00:00Z")
                }))
            ),
            Component(
                id: "checklist-1", name: "CL", iconSystemName: "checklist",
                body: .checklist(ChecklistData(title: "CL", items: (1...4).map { i in
                    ChecklistItem(text: "row \(i)")
                }))
            ),
        ]
        let summary = CanvasSummary.build(myApp: myApp)
        let byId = Dictionary(uniqueKeysWithValues: summary.components.map { ($0.id, $0) })
        #expect(byId["tracker-1"]?.itemCount == 3)
        #expect(byId["calendar-1"]?.itemCount == 2)
        #expect(byId["checklist-1"]?.itemCount == 4)
    }

    @Test("Component JSON without a summary field decodes with summary = nil — pre-0.0.41 blob compat")
    func componentBackwardCompat() throws {
        let json = #"""
        {"id":"tracker-1","name":"T","iconSystemName":"list.bullet","body":{"kind":"tracker","data":{"title":"T","fields":[],"items":[],"filter":{},"viewMode":"grid"}}}
        """#
        let decoded = try JSONDecoder().decode(Component.self, from: Data(json.utf8))
        #expect(decoded.summary == nil)
        #expect(decoded.name == "T")
    }

    @Test("setComponentSummary mutator round-trips through the canvas summary")
    func setComponentSummaryRoundTrip() {
        let myApp = makeMyApp()
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.setTracker(title: "T", fields: [FieldDef(name: "x", type: .text)], myAppId: myApp.id)
        let changed = store.setComponentSummary(forKind: "tracker", summary: "rows are TODOs", myAppId: myApp.id)
        #expect(changed == true)
        let summary = CanvasSummary.build(myApp: store.myApps[0])
        #expect(summary.components.first?.summary == "rows are TODOs")

        // Clearing works too — pass nil or whitespace.
        let cleared = store.setComponentSummary(forKind: "tracker", summary: "   ", myAppId: myApp.id)
        #expect(cleared == true)
        let after = CanvasSummary.build(myApp: store.myApps[0])
        #expect(after.components.first?.summary == nil)
    }

    // MARK: - truncateForPreview helper (still used by the discovery tools)

    @Test("truncateForPreview leaves under-budget strings alone")
    func shortStringsUnchanged() {
        #expect(truncateForPreview("hello", budget: 60) == "hello")
    }

    @Test("truncateForPreview cuts over-budget strings with the PREVIEW END marker")
    func longStringsTruncated() {
        let s = String(repeating: "abc", count: 30)
        let out = truncateForPreview(s, budget: 60)
        #expect(out.hasSuffix(" [PREVIEW END]"))
        #expect(out.dropLast(" [PREVIEW END]".count).count == 60)
    }
}
