import Foundation
import Testing
@testable import PupaApp

/// Guards the row-selection cost that keeps a large tracker interactive.
/// `TrackerFiltering.visibleEntries` runs on every render of both tracker
/// views, over every item — so the string work it does per row is the board's
/// per-frame budget, and anything hoisted out of that loop must stay hoisted.
///
/// Deterministic by construction: these count lowercasings rather than timing
/// the pass, so they mean the same thing on a loaded machine. Same reason
/// `CalculatorResolvePerfTests` counts parses.
@Suite("Tracker filtering cost")
struct TrackerFilteringPerfTests {

    private static let fields: [FieldDef] = [
        FieldDef(name: "title", type: .text),
        FieldDef(name: "notes", type: .text),
        FieldDef(name: "owner", type: .text),
        FieldDef(name: "status", type: .select, options: ["Open", "Done"]),
        FieldDef(name: "cover", type: .image),
        FieldDef(name: "link", type: .link),
    ]

    /// `count` rows, half Open and half Done. "title" always matches "row",
    /// so a query on it hits the first searchable field.
    private static func board(_ count: Int) -> [TrackerItem] {
        (0..<count).map { i in
            TrackerItem(values: [
                "title": "Row \(i)",
                "notes": "Some notes for row \(i)",
                "owner": i.isMultiple(of: 3) ? "Ana" : "Bo",
                "status": i.isMultiple(of: 2) ? "Open" : "Done",
                "cover": "https://example.com/\(i).png",
                "link": "https://example.com/item/\(i)",
            ])
        }
    }

    private func entries(
        items: [TrackerItem],
        filter: [String: String] = [:],
        query: String = ""
    ) -> [TrackerFiltering.Entry] {
        TrackerFiltering.resetCountersForTesting()
        return TrackerFiltering.visibleEntries(
            items: items, fields: Self.fields, filter: filter, query: query)
    }

    /// The default state of every board on every render: no filter, no search.
    /// It must cost no string work per row at all — `needle.isEmpty` short
    /// circuits before `matchesQuery`. Dropping that guard would make an idle
    /// 500-row board lowercase 2500 values per frame.
    @Test("An idle board scans no values at all")
    func idleBoardDoesNoPerRowWork() {
        let rows = entries(items: Self.board(500))
        #expect(rows.count == 500)
        #expect(TrackerFiltering.valueScanCountForTesting == 0)
    }

    /// The needle and each filter value are normalised once per call. If either
    /// slid into the row loop the count would scale with the board.
    @Test("Normalisation is once per call, not once per row")
    func normalisationDoesNotScaleWithItemCount() {
        _ = entries(items: Self.board(20), filter: ["status": "Open"], query: "  RoW  ")
        let small = TrackerFiltering.normalizeCountForTesting

        _ = entries(items: Self.board(2_000), filter: ["status": "Open"], query: "  RoW  ")
        let large = TrackerFiltering.normalizeCountForTesting

        // 1 needle + 1 active filter value, at both sizes.
        #expect(small == 2)
        #expect(large == small, "a 100x board must not renormalise the query")
    }

    /// Empty filter entries are dropped before the loop, so they cost neither
    /// a normalisation nor a per-row comparison.
    @Test("Cleared filter entries cost nothing")
    func clearedFilterEntriesAreDroppedUpFront() {
        let rows = entries(items: Self.board(100), filter: ["status": "", "owner": ""])
        #expect(rows.count == 100)
        #expect(TrackerFiltering.normalizeCountForTesting == 1, "the needle only")
        #expect(TrackerFiltering.valueScanCountForTesting == 0)
    }

    /// `matchesQuery` is `fields.contains { … }`, which stops at the first hit.
    /// Rewriting it as a map-then-check would silently cost every searchable
    /// field on every row.
    @Test("Query matching stops at the first matching field")
    func queryMatchingShortCircuits() {
        // "row" is in "title", the first searchable field, so every row
        // matches on its first probe.
        let rows = entries(items: Self.board(100), query: "row")
        #expect(rows.count == 100)
        #expect(TrackerFiltering.valueScanCountForTesting == 100)

        // "notes" only appears in the second searchable field, so each row
        // costs two probes — still not all five.
        let byNotes = entries(items: Self.board(100), query: "some notes")
        #expect(byNotes.count == 100)
        #expect(TrackerFiltering.valueScanCountForTesting == 200)
    }

    /// A row rejected by the select filter must never reach the query scan —
    /// the `guard … else { continue }` ordering is what keeps filter+search
    /// cheap on a narrowed board.
    @Test("Filtered-out rows are never searched")
    func filterRejectionSkipsTheQueryScan() {
        let rows = entries(items: Self.board(100), filter: ["status": "Open"], query: "row")
        #expect(rows.count == 50)
        // 100 filter probes + 50 query probes on the survivors only.
        // Searching first would cost 100 query probes instead of 50.
        #expect(TrackerFiltering.valueScanCountForTesting == 150)
    }

    /// `.image` values are URLs and are excluded from search. Beyond the
    /// "https matches everything" correctness point, it keeps a hero column
    /// from adding a probe per row.
    @Test("Image fields are not scanned")
    func imageFieldsAreExcludedFromSearch() {
        // Present in the image field only — no row may match, and the scan
        // must stop after the four non-image searchable fields per row.
        let rows = entries(items: Self.board(10), query: ".png")
        #expect(rows.isEmpty)
        // title, notes, owner, status, link — five searchable, image excluded.
        #expect(TrackerFiltering.valueScanCountForTesting == 50)
    }
}
