import Foundation
import Testing
@testable import PupaApp

/// Tests for the chart component (Phase 2 of #20, #22): Codable round-trip +
/// legacy decode across all three `ChartSource` arms, `ChartResolver`
/// integration (tracker group/reduce, calculatorRows, inline), empty-source
/// handling, and the line/bar x-axis ascending ordering.
@MainActor
@Suite("Chart component")
struct ChartTests {

    private func freshStore() -> (MyAppStore, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "chart.pie", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.addComponent(kind: "chart", name: "Chart", iconSystemName: "chart.pie", myAppId: myApp.id)
        return (store, myApp.id)
    }

    private func components(_ store: MyAppStore, _ id: UUID) -> [Component] {
        store.myApps.first(where: { $0.id == id })?.components ?? []
    }

    // MARK: - Codec

    @Test("Round-trip Codable preserves every source arm")
    func roundTrip() throws {
        for source: ChartSource in [
            .tracker(componentId: "tracker-1", groupBy: "cuisine", valueField: "amount", reduce: .sum, filter: ["cuisine": "African"], xIsNumericOrDate: false),
            .calculatorRows(componentId: "calculator-1", keys: ["total", "share"]),
            .inline(points: [ChartPoint(label: "Jan", x: 1, y: 10), ChartPoint(label: "Feb", x: 2, y: 20)]),
        ] {
            let original = ChartData(title: "Plot", kind: .pie, source: source)
            let data = try JSONEncoder().encode(CanvasApp.chart(original))
            let decoded = try JSONDecoder().decode(CanvasApp.self, from: data)
            guard case .chart(let restored) = decoded else {
                Issue.record("decoded as \(decoded.kindString) — expected chart")
                return
            }
            #expect(restored.title == "Plot")
            #expect(restored.kind == .pie)
            #expect(restored.source == source)
        }
    }

    @Test("Legacy-ish JSON (missing kind/source fields) decodes with defaults")
    func legacyDecode() throws {
        // No `kind` (→ bar), a tracker source missing filter / xIsNumericOrDate.
        let json = """
        {
          "kind": "chart",
          "data": {
            "title": "Legacy",
            "source": { "type": "tracker", "componentId": "tracker-1", "groupBy": "month", "valueField": "amt", "reduce": "sum" }
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CanvasApp.self, from: json)
        guard case .chart(let c) = decoded else {
            Issue.record("expected chart")
            return
        }
        #expect(c.kind == .bar)   // defaulted
        if case .tracker(_, _, _, let reduce, let filter, let xIsNumericOrDate) = c.source {
            #expect(reduce == .sum)
            #expect(filter.isEmpty)
            #expect(xIsNumericOrDate == false)
        } else {
            Issue.record("expected tracker source")
        }
    }

    @Test("inlineChart on a calculator decodes; Phase-1 blob (no inlineChart) stays nil")
    func calculatorInlineChartCompat() throws {
        // Phase-1 calculator blob — no inlineChart key.
        let phase1 = """
        { "kind": "calculator", "data": { "title": "C", "rows": [] } }
        """.data(using: .utf8)!
        guard case .calculator(let c1) = try JSONDecoder().decode(CanvasApp.self, from: phase1) else {
            Issue.record("expected calculator"); return
        }
        #expect(c1.inlineChart == nil)

        // Round-trip with an inlineChart set.
        let withChart = CalculatorData(title: "C", rows: [], inlineChart: ChartData(title: "Embedded", kind: .bar, source: .inline(points: [ChartPoint(label: "a", y: 1)])))
        let blob = try JSONEncoder().encode(CanvasApp.calculator(withChart))
        guard case .calculator(let c2) = try JSONDecoder().decode(CanvasApp.self, from: blob) else {
            Issue.record("expected calculator"); return
        }
        #expect(c2.inlineChart?.title == "Embedded")
    }

    // MARK: - Resolver

    @Test("tracker source groups + reduces into one point per bucket")
    func resolveTracker() {
        let (store, id) = freshStore()
        store.addComponent(kind: "tracker", name: "Expenses", iconSystemName: "list.bullet", myAppId: id)
        store.setTracker(title: "Expenses",
                         fields: [FieldDef(name: "amount", type: .number), FieldDef(name: "cuisine", type: .text)],
                         myAppId: id)
        store.addItem(["amount": "20", "cuisine": "African"], myAppId: id)
        store.addItem(["amount": "30", "cuisine": "African"], myAppId: id)
        store.addItem(["amount": "50", "cuisine": "Italian"], myAppId: id)
        let trackerId = components(store, id).first(where: {
            if case .tracker = $0.body { return true }; return false
        })!.id

        let source: ChartSource = .tracker(componentId: trackerId, groupBy: "cuisine", valueField: "amount", reduce: .sum, filter: [:], xIsNumericOrDate: false)
        let series = ChartResolver.resolve(source, components: components(store, id))
        #expect(series.count == 1)
        let byLabel = Dictionary(uniqueKeysWithValues: series[0].points.map { ($0.label, $0.y) })
        #expect(byLabel["African"] == 50)
        #expect(byLabel["Italian"] == 50)
    }

    @Test("calculatorRows source plots resolved row values")
    func resolveCalculatorRows() {
        let (store, id) = freshStore()
        store.addComponent(kind: "calculator", name: "Calc", iconSystemName: "function", myAppId: id)
        store.addCalcRow(key: "a", name: "A", kind: .variable(value: 10, control: .plain), myAppId: id)
        store.addCalcRow(key: "b", name: "B", kind: .variable(value: 5, control: .plain), myAppId: id)
        store.addCalcRow(key: "sum", name: "Sum", kind: .formula(expression: "a + b"), myAppId: id)
        let calcId = components(store, id).first(where: {
            if case .calculator = $0.body { return true }; return false
        })!.id

        let source: ChartSource = .calculatorRows(componentId: calcId, keys: ["a", "b", "sum"])
        let series = ChartResolver.resolve(source, components: components(store, id))
        #expect(series.count == 1)
        let byLabel = Dictionary(uniqueKeysWithValues: series[0].points.map { ($0.label, $0.y) })
        #expect(byLabel["A"] == 10)
        #expect(byLabel["B"] == 5)
        #expect(byLabel["Sum"] == 15)
    }

    @Test("inline source returns its points verbatim")
    func resolveInline() {
        let (store, id) = freshStore()
        let source: ChartSource = .inline(points: [ChartPoint(label: "x", y: 1), ChartPoint(label: "y", y: 2)])
        let series = ChartResolver.resolve(source, components: components(store, id))
        #expect(series.first?.points.count == 2)
        #expect(ChartResolver.pointCount(source, components: components(store, id)) == 2)
    }

    @Test("empty / broken source resolves to no series, no crash")
    func resolveEmpty() {
        let (store, id) = freshStore()
        // Tracker source pointing at a non-existent component.
        let broken: ChartSource = .tracker(componentId: "nope", groupBy: "g", valueField: "v", reduce: .sum, filter: [:], xIsNumericOrDate: false)
        #expect(ChartResolver.resolve(broken, components: components(store, id)).isEmpty)
        // Empty inline.
        #expect(ChartResolver.resolve(.inline(points: []), components: components(store, id)).isEmpty)
    }

    @Test("line/bar over a date field orders points ascending by x")
    func lineXOrdering() {
        let (store, id) = freshStore()
        store.addComponent(kind: "tracker", name: "Sales", iconSystemName: "list.bullet", myAppId: id)
        store.setTracker(title: "Sales",
                         fields: [FieldDef(name: "amount", type: .number), FieldDef(name: "date", type: .text)],
                         myAppId: id)
        // Inserted out of order on purpose.
        store.addItem(["amount": "30", "date": "2026-03-01"], myAppId: id)
        store.addItem(["amount": "10", "date": "2026-01-01"], myAppId: id)
        store.addItem(["amount": "20", "date": "2026-02-01"], myAppId: id)
        let trackerId = components(store, id).first(where: {
            if case .tracker = $0.body { return true }; return false
        })!.id

        let source: ChartSource = .tracker(componentId: trackerId, groupBy: "date", valueField: "amount", reduce: .sum, filter: [:], xIsNumericOrDate: true)
        let series = ChartResolver.resolve(source, components: components(store, id))
        let labels = series[0].points.map(\.label)
        #expect(labels == ["2026-01-01", "2026-02-01", "2026-03-01"])
        // x values are ascending too.
        let xs = series[0].points.compactMap(\.x)
        #expect(xs == xs.sorted())
    }

    // MARK: - Mutators

    @Test("setChart / patchChart / setChartKind edit the chart in place")
    func mutators() {
        let (store, id) = freshStore()
        store.setChart(title: "Plot", kind: .bar, source: .inline(points: [ChartPoint(label: "a", y: 1)]), myAppId: id)
        store.setChartKind(.pie, myAppId: id)
        var patch = MyAppStore.ChartPatch()
        patch.title = "Renamed"
        #expect(store.patchChart(patch: patch, myAppId: id))

        guard case .chart(let c)? = components(store, id).first(where: {
            if case .chart = $0.body { return true }; return false
        })?.body else {
            Issue.record("expected chart"); return
        }
        #expect(c.title == "Renamed")
        #expect(c.kind == .pie)
    }
}
