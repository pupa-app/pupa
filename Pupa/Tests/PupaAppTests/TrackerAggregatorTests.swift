import Foundation
import Testing
@testable import PupaApp

/// Tests for the pure tracker reduce: every reduce verb, the
/// case-insensitive AND equality filter (the "African restaurants"
/// isolation), and tolerant numeric parsing (currency / commas / percent /
/// non-numeric / empty).
@Suite("TrackerAggregator")
struct TrackerAggregatorTests {

    private func items(_ rows: [[String: String]]) -> [TrackerItem] {
        rows.map { TrackerItem(values: $0) }
    }

    private let expenses = [
        ["amount": "20", "cuisine": "African"],
        ["amount": "30", "cuisine": "African"],
        ["amount": "50", "cuisine": "Italian"],
        ["amount": "10", "cuisine": "italian"],   // lowercase — same group
    ]

    // MARK: - Reduces

    @Test("sum / avg / min / max / count over all items")
    func reduces() {
        let rows = items(expenses)
        #expect(TrackerAggregator.reduce(.sum, field: "amount", items: rows).value == 110)
        #expect(TrackerAggregator.reduce(.avg, field: "amount", items: rows).value == 27.5)
        #expect(TrackerAggregator.reduce(.min, field: "amount", items: rows).value == 10)
        #expect(TrackerAggregator.reduce(.max, field: "amount", items: rows).value == 50)
        #expect(TrackerAggregator.reduce(.count, field: "amount", items: rows).value == 4)
    }

    // MARK: - Filter isolation

    @Test("case-insensitive AND equality filter isolates a category")
    func filterIsolation() {
        let rows = items(expenses)
        let african = TrackerAggregator.reduce(.sum, field: "amount", items: rows, filter: ["cuisine": "african"])
        #expect(african.value == 50)        // 20 + 30, case-insensitive match
        #expect(african.matchedItems == 2)

        let italian = TrackerAggregator.reduce(.sum, field: "amount", items: rows, filter: ["cuisine": "Italian"])
        #expect(italian.value == 60)        // 50 + 10 (lowercase italian counted)
        #expect(italian.matchedItems == 2)
    }

    @Test("count respects the filter")
    func filteredCount() {
        let rows = items(expenses)
        #expect(TrackerAggregator.reduce(.count, field: "amount", items: rows, filter: ["cuisine": "African"]).value == 2)
    }

    @Test("multi-key filter ANDs every clause")
    func multiKeyFilter() {
        let rows = items([
            ["amount": "5", "cuisine": "African", "meal": "lunch"],
            ["amount": "7", "cuisine": "African", "meal": "dinner"],
        ])
        let r = TrackerAggregator.reduce(.sum, field: "amount", items: rows, filter: ["cuisine": "African", "meal": "lunch"])
        #expect(r.value == 5)
        #expect(r.matchedItems == 1)
    }

    @Test("a filter key absent on an item fails the match")
    func missingKeyFails() {
        let rows = items([["amount": "5"]]) // no cuisine field
        let r = TrackerAggregator.reduce(.sum, field: "amount", items: rows, filter: ["cuisine": "African"])
        #expect(r.matchedItems == 0)
        #expect(r.value == 0)
    }

    // MARK: - Numeric parsing

    @Test("tolerant numeric parse: currency, commas, percent, whitespace")
    func tolerantParse() {
        let rows = items([
            ["amount": "$1,234.50"],
            ["amount": " 10 "],
            ["amount": "5%"],
        ])
        let r = TrackerAggregator.reduce(.sum, field: "amount", items: rows)
        #expect(abs(r.value - 1249.5) < 1e-9)
        #expect(r.numericValues == 3)
    }

    @Test("non-numeric and empty values are skipped, not counted as zero")
    func nonNumericSkipped() {
        let rows = items([
            ["amount": "10"],
            ["amount": "n/a"],
            ["amount": ""],
            ["amount": "20"],
        ])
        let r = TrackerAggregator.reduce(.sum, field: "amount", items: rows)
        #expect(r.value == 30)
        #expect(r.matchedItems == 4)   // all pass the (empty) filter
        #expect(r.numericValues == 2)  // only 10 and 20 parsed
    }

    @Test("avg of no numeric values is zero with numericValues == 0")
    func avgOfNothing() {
        let rows = items([["amount": "x"], ["amount": ""]])
        let r = TrackerAggregator.reduce(.avg, field: "amount", items: rows)
        #expect(r.value == 0)
        #expect(r.numericValues == 0)
    }

    // MARK: - AggregateSpec convenience

    @Test("reduce(spec, over: tracker) reads field/reduce/filter off the spec")
    func specConvenience() {
        let tracker = TrackerData(
            title: "Expenses",
            fields: [FieldDef(name: "amount", type: .number), FieldDef(name: "cuisine", type: .text)],
            items: items(expenses)
        )
        let spec = AggregateSpec(sourceComponentId: "tracker-1", fieldName: "amount", reduce: .sum, filter: ["cuisine": "African"])
        #expect(TrackerAggregator.reduce(spec, over: tracker).value == 50)
    }
}
