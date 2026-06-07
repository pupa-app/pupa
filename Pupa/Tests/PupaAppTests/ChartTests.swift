import Foundation
import Testing
@testable import PupaApp

/// Tests for the chart component (Phase 2 of #20, #22 + multi-series): Codable
/// round-trip across every `ChartSeriesSource` arm, `ChartResolver`
/// integration (tracker / calculatorRows / calculatorList / inline),
/// multi-series resolution + default names, empty-source handling, line x
/// ordering, and the store mutators.
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

    @Test("Round-trip Codable preserves multi-series + every source arm")
    func roundTrip() throws {
        let original = ChartData(title: "Plot", kind: .line, series: [
            ChartSeriesSpec(name: "A", colorHex: "#FF0000",
                source: .tracker(componentId: "tracker-1", groupBy: "month", valueField: "amount", reduce: .sum, filter: ["cuisine": "African"], xIsNumericOrDate: true)),
            ChartSeriesSpec(name: "B", source: .calculatorRows(componentId: "calculator-1", keys: ["total", "share"])),
            ChartSeriesSpec(source: .calculatorList(componentId: "calculator-1", key: "curve")),
            ChartSeriesSpec(source: .inline(points: [ChartPoint(label: "Jan", x: 1, y: 10)])),
        ])
        let data = try JSONEncoder().encode(CanvasApp.chart(original))
        let decoded = try JSONDecoder().decode(CanvasApp.self, from: data)
        guard case .chart(let restored) = decoded else {
            Issue.record("decoded as \(decoded.kindString) — expected chart")
            return
        }
        #expect(restored.title == "Plot")
        #expect(restored.kind == .line)
        #expect(restored.series.count == 4)
        #expect(restored.series[0].name == "A")
        #expect(restored.series[0].colorHex == "#FF0000")
        #expect(restored.series[0].source == .tracker(componentId: "tracker-1", groupBy: "month", valueField: "amount", reduce: .sum, filter: ["cuisine": "African"], xIsNumericOrDate: true))
        #expect(restored.series[2].source == .calculatorList(componentId: "calculator-1", key: "curve"))
    }

    @Test("calculatorLinkedSweep source round-trips via Codable")
    func calculatorLinkedSweepRoundTrip() throws {
        let original = ChartData(title: "Plot", kind: .line,
            source: .calculatorLinkedSweep(componentId: "calculator-1", key: "by_house"))
        let blob = try JSONEncoder().encode(CanvasApp.chart(original))
        guard case .chart(let restored) = try JSONDecoder().decode(CanvasApp.self, from: blob) else {
            Issue.record("expected chart"); return
        }
        #expect(restored.series.first?.source == .calculatorLinkedSweep(componentId: "calculator-1", key: "by_house"))
    }

    @Test("inlineChart on a calculator decodes; Phase-1 blob (no inlineChart) stays nil")
    func calculatorInlineChartCompat() throws {
        let phase1 = """
        { "kind": "calculator", "data": { "title": "C", "rows": [] } }
        """.data(using: .utf8)!
        guard case .calculator(let c1) = try JSONDecoder().decode(CanvasApp.self, from: phase1) else {
            Issue.record("expected calculator"); return
        }
        #expect(c1.inlineChart == nil)

        let withChart = CalculatorData(title: "C", rows: [], inlineChart: ChartData(title: "Embedded", kind: .bar, source: .inline(points: [ChartPoint(label: "a", y: 1)])))
        let blob = try JSONEncoder().encode(CanvasApp.calculator(withChart))
        guard case .calculator(let c2) = try JSONDecoder().decode(CanvasApp.self, from: blob) else {
            Issue.record("expected calculator"); return
        }
        #expect(c2.inlineChart?.title == "Embedded")
        #expect(c2.inlineChart?.series.count == 1)
    }

    @Test("extraCharts round-trip; a blob without the key decodes to []")
    func calculatorExtraChartsCompat() throws {
        let noKey = """
        { "kind": "calculator", "data": { "title": "C", "rows": [] } }
        """.data(using: .utf8)!
        guard case .calculator(let c1) = try JSONDecoder().decode(CanvasApp.self, from: noKey) else {
            Issue.record("expected calculator"); return
        }
        #expect(c1.extraCharts.isEmpty)

        let withExtras = CalculatorData(
            title: "C", rows: [],
            inlineChart: ChartData(title: "Bar", kind: .bar, source: .inline(points: [ChartPoint(label: "a", y: 1)])),
            extraCharts: [ChartData(title: "Line", kind: .line, source: .inline(points: [ChartPoint(label: "1", x: 1, y: 2)]))]
        )
        let blob = try JSONEncoder().encode(CanvasApp.calculator(withExtras))
        guard case .calculator(let c2) = try JSONDecoder().decode(CanvasApp.self, from: blob) else {
            Issue.record("expected calculator"); return
        }
        #expect(c2.inlineChart?.title == "Bar")
        #expect(c2.extraCharts.count == 1)
        #expect(c2.extraCharts.first?.kind == .line)
    }

    @Test("Home Buying seeds a live bar chart + a live buy-vs-rent net-worth line chart")
    func homeBuyingBuyVsRentChart() throws {
        let app = HomeBuyingExample.make()
        guard case .calculator(let calc) = app.components.first(where: { $0.id == "calculator-1" })?.body else {
            Issue.record("expected calculator-1"); return
        }
        #expect(calc.inlineChart?.kind == .bar)
        #expect(calc.extraCharts.count == 1)

        let line = try #require(calc.extraCharts.first)
        #expect(line.kind == .line)
        #expect(line.series.count == 2)   // own vs. rent, both live sweep curves

        // Both series are live calculatorList sources (no seed-static inline).
        for spec in line.series {
            guard case .calculatorList = spec.source else {
                Issue.record("expected calculatorList series, got \(spec.source)"); continue
            }
        }

        // Resolve the whole chart against the seeded app: both wealth curves
        // span 30 years and START at the same value (down payment), since both
        // strategies deploy the same money — the apples-to-apples property.
        let resolved = ChartResolver.resolve(line, components: app.components)
        #expect(resolved.count == 2)
        for s in resolved { #expect(s.points.count == 30) }
        let own = try #require(resolved.first(where: { $0.name.contains("Own") }))
        let rent = try #require(resolved.first(where: { $0.name.contains("Rent") }))
        // Year 1 nearly equal (both ≈ down payment); allow a small first-year gap.
        let ownY1 = try #require(own.points.first?.y)
        let rentY1 = try #require(rent.points.first?.y)
        #expect(abs(ownY1 - rentY1) / max(ownY1, rentY1) < 0.15)
        // Neither curve plunges negative — net worth stays non-negative.
        #expect(own.points.allSatisfy { $0.y >= 0 })
        #expect(rent.points.allSatisfy { $0.y >= 0 })
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

        let data = ChartData(title: "C", kind: .pie, source: .tracker(componentId: trackerId, groupBy: "cuisine", valueField: "amount", reduce: .sum, filter: [:], xIsNumericOrDate: false))
        let series = ChartResolver.resolve(data, components: components(store, id))
        #expect(series.count == 1)
        let byLabel = Dictionary(uniqueKeysWithValues: series[0].points.map { ($0.label, $0.y) })
        #expect(byLabel["African"] == 50)
        #expect(byLabel["Italian"] == 50)
    }

    @Test("two tracker series overlay; default names come from the value fields")
    func resolveMultiSeries() {
        let (store, id) = freshStore()
        store.addComponent(kind: "tracker", name: "Sales", iconSystemName: "list.bullet", myAppId: id)
        store.setTracker(title: "Sales",
                         fields: [FieldDef(name: "revenue", type: .number), FieldDef(name: "cost", type: .number), FieldDef(name: "month", type: .text)],
                         myAppId: id)
        store.addItem(["revenue": "100", "cost": "60", "month": "2026-01"], myAppId: id)
        store.addItem(["revenue": "120", "cost": "70", "month": "2026-02"], myAppId: id)
        let trackerId = components(store, id).first(where: {
            if case .tracker = $0.body { return true }; return false
        })!.id

        let data = ChartData(title: "P", kind: .line, series: [
            ChartSeriesSpec(source: .tracker(componentId: trackerId, groupBy: "month", valueField: "revenue", reduce: .sum, filter: [:], xIsNumericOrDate: false)),
            ChartSeriesSpec(source: .tracker(componentId: trackerId, groupBy: "month", valueField: "cost", reduce: .sum, filter: [:], xIsNumericOrDate: false)),
        ])
        let series = ChartResolver.resolve(data, components: components(store, id))
        #expect(series.count == 2)
        #expect(series[0].name == "revenue")   // default name from valueField
        #expect(series[1].name == "cost")
        #expect(ChartResolver.pointCount(data, components: components(store, id)) == 4)
    }

    @Test("calculatorList source plots a sweep row's array")
    func resolveCalculatorList() {
        let (store, id) = freshStore()
        store.addComponent(kind: "calculator", name: "Calc", iconSystemName: "function", myAppId: id)
        store.addCalcRow(key: "rate", name: "Rate", kind: .variable(value: 1, control: .plain), myAppId: id)
        store.addCalcRow(key: "out", name: "Out", kind: .formula(expression: "rate * 10"), myAppId: id)
        store.addCalcRow(key: "curve", name: "Curve",
                         kind: .list(.sweep(variableKey: "rate", from: 1, to: 3, step: 1, targetKey: "out")), myAppId: id)
        let calcId = components(store, id).first(where: {
            if case .calculator = $0.body { return true }; return false
        })!.id

        let data = ChartData(title: "C", kind: .line, source: .calculatorList(componentId: calcId, key: "curve"))
        let series = ChartResolver.resolve(data, components: components(store, id))
        #expect(series.count == 1)
        let ys = series[0].points.map(\.y)
        #expect(ys == [10, 20, 30])   // rate swept 1,2,3 → out = rate*10
    }

    @Test("empty / broken source resolves to no series, no crash")
    func resolveEmpty() {
        let (store, id) = freshStore()
        let broken = ChartData(title: "C", kind: .bar, source: .tracker(componentId: "nope", groupBy: "g", valueField: "v", reduce: .sum, filter: [:], xIsNumericOrDate: false))
        #expect(ChartResolver.resolve(broken, components: components(store, id)).isEmpty)
        #expect(ChartResolver.resolve(ChartData(title: "C", kind: .bar, source: .inline(points: [])), components: components(store, id)).isEmpty)
    }

    @Test("line over a date field orders points ascending by x")
    func lineXOrdering() {
        let (store, id) = freshStore()
        store.addComponent(kind: "tracker", name: "Sales", iconSystemName: "list.bullet", myAppId: id)
        store.setTracker(title: "Sales",
                         fields: [FieldDef(name: "amount", type: .number), FieldDef(name: "date", type: .text)],
                         myAppId: id)
        store.addItem(["amount": "30", "date": "2026-03-01"], myAppId: id)
        store.addItem(["amount": "10", "date": "2026-01-01"], myAppId: id)
        store.addItem(["amount": "20", "date": "2026-02-01"], myAppId: id)
        let trackerId = components(store, id).first(where: {
            if case .tracker = $0.body { return true }; return false
        })!.id

        let data = ChartData(title: "C", kind: .line, source: .tracker(componentId: trackerId, groupBy: "date", valueField: "amount", reduce: .sum, filter: [:], xIsNumericOrDate: true))
        let series = ChartResolver.resolve(data, components: components(store, id))
        #expect(series[0].points.map(\.label) == ["2026-01-01", "2026-02-01", "2026-03-01"])
    }

    // MARK: - Mutators

    @Test("set / patch / kind / add / remove series edit the chart in place")
    func mutators() {
        let (store, id) = freshStore()
        store.setChart(title: "Plot", kind: .bar,
                       series: [ChartSeriesSpec(source: .inline(points: [ChartPoint(label: "a", y: 1)]))], myAppId: id)
        store.setChartKind(.line, myAppId: id)
        #expect(store.addChartSeries([ChartSeriesSpec(source: .inline(points: [ChartPoint(label: "b", y: 2)]))], myAppId: id) == 2)
        var patch = MyAppStore.ChartPatch()
        patch.title = "Renamed"
        #expect(store.patchChart(patch: patch, myAppId: id))
        #expect(store.removeChartSeries(index: 0, myAppId: id))

        guard case .chart(let c)? = components(store, id).first(where: {
            if case .chart = $0.body { return true }; return false
        })?.body else {
            Issue.record("expected chart"); return
        }
        #expect(c.title == "Renamed")
        #expect(c.kind == .line)
        #expect(c.series.count == 1)
    }
}
