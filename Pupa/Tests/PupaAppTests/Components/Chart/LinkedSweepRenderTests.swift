import Foundation
import SwiftUI
import Testing
@testable import PupaApp

/// A `linkedSweep` row resolves to one curve per linked item, but neither
/// surface that is supposed to draw it was reading `.series` — the chart asked
/// the single-series entry point (which reports no points for a multi-series
/// source) and the calculator row read `.list` (nil on a `linkedSweep`). Both
/// rendered an empty state for a perfectly valid model.
///
/// These cover the two display seams end-to-end from a real store.
@MainActor
@Suite("linkedSweep rendering")
struct LinkedSweepRenderTests {

    /// A calculator with a `linkedSweep` row over three houses, plus the
    /// tracker it links to. Returns the store, the MyApp id and the calculator
    /// component id.
    private func housesModel() -> (MyAppStore, UUID, String) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "house", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        let id = myApp.id

        store.addComponent(kind: "tracker", name: "Houses", iconSystemName: "house", myAppId: id)
        store.setTracker(title: "Houses",
                         fields: [FieldDef(name: "name", type: .text), FieldDef(name: "price", type: .number)],
                         myAppId: id)
        for (name, price) in [("Maple", "100"), ("Oak", "200"), ("Pine", "300")] {
            store.addItem(["name": name, "price": price], myAppId: id)
        }
        let trackerId = components(store, id).first(where: {
            if case .tracker = $0.body { return true }; return false
        })!.id
        let refs = trackerItems(store, id, trackerId).map {
            ComponentItemRef(componentId: trackerId, itemId: $0.id)
        }

        store.addComponent(kind: "calculator", name: "Calc", iconSystemName: "function", myAppId: id)
        let calcId = components(store, id).first(where: {
            if case .calculator = $0.body { return true }; return false
        })!.id
        store.addCalcRow(key: "price", name: "Price",
                         kind: .linkedField(LinkedFieldSpec(ref: refs[0], fieldName: "price")), myAppId: id)
        store.addCalcRow(key: "year", name: "Year",
                         kind: .variable(value: 1, control: .slider(min: 1, max: 3, step: 1)), myAppId: id)
        store.addCalcRow(key: "total", name: "Total",
                         kind: .formula(expression: "price * year"), myAppId: id)
        store.addCalcRow(key: "curves", name: "Curve per house",
                         kind: .list(.linkedSweep(refs: refs, linkedRowKey: "price", variableKey: "year",
                                                  from: 1, to: 3, step: 1, targetKey: "total")), myAppId: id)
        return (store, id, calcId)
    }

    private func components(_ store: MyAppStore, _ id: UUID) -> [Component] {
        store.myApps.first(where: { $0.id == id })?.components ?? []
    }

    private func trackerItems(_ store: MyAppStore, _ id: UUID, _ componentId: String) -> [TrackerItem] {
        for c in components(store, id) where c.id == componentId {
            if case .tracker(let t) = c.body { return t.items }
        }
        return []
    }

    // MARK: - Seam 1: the chart

    @Test("A calculatorLinkedSweep chart draws one line per linked item")
    func chartFansOutOneSeriesPerRef() {
        let (store, id, calcId) = housesModel()
        let chart = ChartData(title: "By house", kind: .line,
                              source: .calculatorLinkedSweep(componentId: calcId, key: "curves"))

        let display = ChartResolver.displaySeries(chart, components: components(store, id))

        #expect(display.count == 3)
        #expect(display.map(\.series.name) == ["Maple", "Oak", "Pine"])
        // price * year, year swept 1...3.
        #expect(display[0].series.points.map(\.y) == [100, 200, 300])
        #expect(display[2].series.points.map(\.y) == [300, 600, 900])
    }

    @Test("A calculatorList source pointed at a linkedSweep row plots nothing")
    func calculatorListOnLinkedSweepIsEmpty() {
        let (store, id, calcId) = housesModel()
        let chart = ChartData(title: "One", kind: .line,
                              source: .calculatorList(componentId: calcId, key: "curves"))
        // `curves` is a linkedSweep, so it has no flat `list` — nothing to plot.
        #expect(ChartResolver.displaySeries(chart, components: components(store, id)).isEmpty)
    }

    @Test("A genuine single-series source yields exactly one series, id preserved")
    func singleSourceUnaffected() {
        let (store, id, calcId) = housesModel()
        let spec = ChartSeriesSpec(name: "Total",
                                   source: .calculatorRows(componentId: calcId, keys: ["total"]))
        let chart = ChartData(title: "One", kind: .bar, series: [spec])

        let display = ChartResolver.displaySeries(chart, components: components(store, id))
        #expect(display.count == 1)
        #expect(display[0].series.name == "Total")
        // The spec's identity must survive the rename pass.
        #expect(display[0].series.id == spec.id)
    }

    @Test("Duplicate series names are disambiguated for the legend")
    func duplicateNamesDisambiguated() {
        let (store, id, calcId) = housesModel()
        let spec = ChartSeriesSpec(name: "Total", source: .calculatorRows(componentId: calcId, keys: ["total"]))
        let other = ChartSeriesSpec(name: "Total", source: .calculatorRows(componentId: calcId, keys: ["total"]))
        let chart = ChartData(title: "Dup", kind: .bar, series: [spec, other])

        let names = ChartResolver.displaySeries(chart, components: components(store, id)).map(\.series.name)
        #expect(names == ["Total", "Total (2)"])
    }

    @Test("A spec's colour override rides along, but never flattens a fanned-out series")
    func colourOverrideAppliesToSingleSeriesOnly() {
        let (store, id, calcId) = housesModel()
        let single = ChartData(title: "One", kind: .bar, series: [
            ChartSeriesSpec(name: "Total", colorHex: "#ff0000",
                            source: .calculatorRows(componentId: calcId, keys: ["total"]))
        ])
        #expect(ChartResolver.displaySeries(single, components: components(store, id))
            .first?.colorHex == "#ff0000")

        // One spec, many curves: a single colour would render them identically,
        // defeating the point of a line per item.
        let fanned = ChartData(title: "Many", kind: .line, series: [
            ChartSeriesSpec(name: "By house", colorHex: "#ff0000",
                            source: .calculatorLinkedSweep(componentId: calcId, key: "curves"))
        ])
        let display = ChartResolver.displaySeries(fanned, components: components(store, id))
        #expect(display.count == 3)
        #expect(display.allSatisfy { $0.colorHex == nil })
    }

    // MARK: - Seam 2: the calculator's own row

    @Test("A linkedSweep row renders its curves instead of an empty state")
    func calculatorRowShowsSeries() {
        let (store, id, calcId) = housesModel()
        var calc: CalculatorData?
        for c in components(store, id) where c.id == calcId {
            if case .calculator(let d) = c.body { calc = d }
        }
        let resolved = CalculatorResolver.resolve(calc!, components: components(store, id))
        let result = resolved.result(forKey: "curves")

        // The resolver has always produced these; the row just never read them.
        #expect(result?.list == nil)
        #expect(result?.series?.count == 3)

        let drawn = CalculatorView.listRowSeries(result)
        #expect(drawn.count == 3)
        #expect(drawn.map(\.name) == ["Maple", "Oak", "Pine"])
    }

    @Test("A plain sweep row still renders its single flat curve")
    func calculatorRowSingleCurveUnaffected() {
        let (store, id, calcId) = housesModel()
        store.addCalcRow(key: "flat", name: "Flat",
                         kind: .list(.sweep(variableKey: "year", from: 1, to: 3, step: 1, targetKey: "total")),
                         myAppId: id)
        var calc: CalculatorData?
        for c in components(store, id) where c.id == calcId {
            if case .calculator(let d) = c.body { calc = d }
        }
        let result = CalculatorResolver.resolve(calc!, components: components(store, id)).result(forKey: "flat")

        let drawn = CalculatorView.listRowSeries(result)
        #expect(drawn.count == 1)
        #expect(drawn[0].points.map(\.y) == [100, 200, 300])
    }

    @Test("A row with neither list nor series draws nothing")
    func calculatorRowEmptyStaysEmpty() {
        #expect(CalculatorView.listRowSeries(nil).isEmpty)
        #expect(CalculatorView.listRowSeries(
            CalculatorResolver.RowResult(value: nil, status: .brokenRef)
        ).isEmpty)
    }

    // MARK: - Same-named linked items

    /// Curve names are linked-item display names — user data, which repeats.
    /// Swift Charts groups colour and legend by name, so two curves sharing one
    /// merge into a single style group and draw as one tangle.
    @Test("Two linked items with the same name still render as two distinct curves")
    func sameNamedRefsStayDistinct() {
        let (store, id, calcId) = twoMaplesModel()
        let chart = ChartData(title: "By house", kind: .line,
                              source: .calculatorLinkedSweep(componentId: calcId, key: "curves"))

        let names = ChartResolver.displaySeries(chart, components: components(store, id))
            .map(\.series.name)
        #expect(names == ["Maple", "Maple (2)"])
    }

    /// The calculator's own row must apply the same rule — otherwise one model
    /// renders two different ways depending on which surface draws it.
    @Test("The calculator row disambiguates same-named curves too")
    func calculatorRowDisambiguatesSameNames() {
        let (store, id, calcId) = twoMaplesModel()
        var calc: CalculatorData?
        for c in components(store, id) where c.id == calcId {
            if case .calculator(let d) = c.body { calc = d }
        }
        let result = CalculatorResolver.resolve(calc!, components: components(store, id))
            .result(forKey: "curves")

        #expect(CalculatorView.listRowSeries(result).map(\.name) == ["Maple", "Maple (2)"])
    }

    @Test("disambiguated leaves already-unique names and identities alone")
    func disambiguatedIsIdentityOnUniqueNames() {
        let input = [
            ChartSeries(id: "a", name: "One", points: [ChartPoint(label: "x", y: 1)]),
            ChartSeries(id: "b", name: "Two", points: [ChartPoint(label: "x", y: 2)]),
        ]
        let out = ChartResolver.disambiguated(input)
        #expect(out.map(\.name) == ["One", "Two"])
        #expect(out.map(\.id) == ["a", "b"])
    }

    /// Two houses that happen to share a display name.
    private func twoMaplesModel() -> (MyAppStore, UUID, String) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "house", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        let id = myApp.id

        store.addComponent(kind: "tracker", name: "Houses", iconSystemName: "house", myAppId: id)
        store.setTracker(title: "Houses",
                         fields: [FieldDef(name: "name", type: .text), FieldDef(name: "price", type: .number)],
                         myAppId: id)
        store.addItem(["name": "Maple", "price": "100"], myAppId: id)
        store.addItem(["name": "Maple", "price": "200"], myAppId: id)
        let trackerId = components(store, id).first(where: {
            if case .tracker = $0.body { return true }; return false
        })!.id
        let refs = trackerItems(store, id, trackerId).map {
            ComponentItemRef(componentId: trackerId, itemId: $0.id)
        }

        store.addComponent(kind: "calculator", name: "Calc", iconSystemName: "function", myAppId: id)
        let calcId = components(store, id).first(where: {
            if case .calculator = $0.body { return true }; return false
        })!.id
        store.addCalcRow(key: "price", name: "Price",
                         kind: .linkedField(LinkedFieldSpec(ref: refs[0], fieldName: "price")), myAppId: id)
        store.addCalcRow(key: "year", name: "Year",
                         kind: .variable(value: 1, control: .slider(min: 1, max: 3, step: 1)), myAppId: id)
        store.addCalcRow(key: "total", name: "Total",
                         kind: .formula(expression: "price * year"), myAppId: id)
        store.addCalcRow(key: "curves", name: "Curve per house",
                         kind: .list(.linkedSweep(refs: refs, linkedRowKey: "price", variableKey: "year",
                                                  from: 1, to: 3, step: 1, targetKey: "total")), myAppId: id)
        return (store, id, calcId)
    }

    /// The seam that was broken: what `ChartContainerView` actually draws.
    /// `body` is a one-line call to `drawable`, so this pins everything from
    /// the spec to the drawn series — short of rendering the view itself,
    /// which would still be needed to catch someone rewiring that one line.
    @Test("What the chart view draws includes every fanned-out curve")
    func chartViewDrawsFannedOutCurves() {
        let (store, id, calcId) = housesModel()
        let chart = ChartData(title: "By house", kind: .line,
                              source: .calculatorLinkedSweep(componentId: calcId, key: "curves"))

        let drawn = ChartContainerView.drawable(chart, components: components(store, id))
        #expect(drawn.series.map(\.name) == ["Maple", "Oak", "Pine"])
        // No override on a fanned-out spec, so Swift Charts picks the colours.
        #expect(drawn.colorByName.isEmpty)
    }

    @Test("A colour override reaches the view as a Color keyed by the drawn name")
    func chartViewCarriesColourOverride() {
        let (store, id, calcId) = housesModel()
        let chart = ChartData(title: "One", kind: .bar, series: [
            ChartSeriesSpec(name: "Total", colorHex: "#ff0000",
                            source: .calculatorRows(componentId: calcId, keys: ["total"]))
        ])
        let drawn = ChartContainerView.drawable(chart, components: components(store, id))
        #expect(drawn.series.map(\.name) == ["Total"])
        #expect(drawn.colorByName["Total"] != nil)
    }

    // MARK: - The naming rule must not emit the collision it prevents

    /// People number their own duplicates by hand, so a generated suffix can
    /// land on a name that literally appears later in the set. Counting source
    /// names would emit two identical "(2)"s — the exact collapse this helper
    /// exists to stop, now at the single chokepoint for every render seam.
    @Test("A generated suffix never collides with a literal one")
    func generatedSuffixAvoidsLiteralName() {
        let input = ["Maple", "Maple", "Maple (2)"].enumerated().map { idx, name in
            ChartSeries(id: "\(idx)", name: name, points: [ChartPoint(label: "x", y: 1)])
        }
        let names = ChartResolver.disambiguated(input).map(\.name)
        // The third item is genuinely *named* "Maple (2)", so it keeps that as
        // its base and gets suffixed in turn. Renumbering it to "Maple (3)"
        // would presume it is a variant of "Maple", which it is not — what
        // matters is that no two names collide.
        #expect(names == ["Maple", "Maple (2)", "Maple (2) (2)"])
        #expect(Set(names).count == names.count)
    }

    @Test("Three of a kind number sequentially")
    func threeWayDuplicate() {
        let input = ["A", "A", "A"].enumerated().map { idx, name in
            ChartSeries(id: "\(idx)", name: name, points: [ChartPoint(label: "x", y: 1)])
        }
        #expect(ChartResolver.disambiguated(input).map(\.name) == ["A", "A (2)", "A (3)"])
    }

    // MARK: - Colour scale

    /// An overridden name must not consume a palette slot, or the remaining
    /// series skip colours and wrap sooner than they need to.
    @Test("The colour range fills un-overridden names from the palette, in order")
    func colourRangeFillsAroundOverrides() {
        let palette = CategoricalPalette.colors
        let range = ColorScaleModifier.range(
            names: ["A", "B", "C"],
            colorByName: ["B": .red]
        )
        #expect(range == [palette[0], .red, palette[1]])
    }

    /// The regression that made the fanned-out curves render identically: a
    /// domain built only from overridden names leaves the rest unstyled.
    @Test("Every series on a partly coloured chart gets its own colour")
    func partlyColouredChartCoversEveryone() {
        let range = ColorScaleModifier.range(
            names: ["Baseline", "Maple", "Oak", "Pine"],
            colorByName: ["Baseline": .red]
        )
        #expect(range.count == 4)
        #expect(range[0] == .red)
        // The three un-overridden curves are distinct from one another.
        #expect(Set(range.dropFirst().map(\.description)).count == 3)
    }

    @Test("The palette wraps rather than running out")
    func paletteWraps() {
        let count = CategoricalPalette.colors.count
        let names = (0..<(count + 2)).map { "s\($0)" }
        let range = ColorScaleModifier.range(names: names, colorByName: ["s0": .black])
        #expect(range.count == count + 2)
        #expect(range[0] == .black)
        // s1 takes palette[0]; the wrap puts palette[0] back at s1 + count.
        #expect(range[1] == CategoricalPalette.colors[0])
        #expect(range[1 + count] == CategoricalPalette.colors[0])
    }

    // MARK: - Colour overrides

    /// The rule keys off the source *kind*, not how many curves a model happens
    /// to produce. Keying off arity meant a one-ref sweep kept its colour and
    /// then silently lost it — and recoloured its first curve — the moment a
    /// second ref was linked.
    @Test("A linkedSweep spec drops its colour override even with a single ref")
    func fanningSpecDropsColourAtEveryRefCount() {
        let (store, id, calcId) = oneHouseModel()
        let chart = ChartData(title: "By house", kind: .line, series: [
            ChartSeriesSpec(name: "By house", colorHex: "#ff0000",
                            source: .calculatorLinkedSweep(componentId: calcId, key: "curves"))
        ])
        let display = ChartResolver.displaySeries(chart, components: components(store, id))
        #expect(display.count == 1)
        #expect(display[0].colorHex == nil)
    }

    /// A spec that resolves to nothing must consume no colour slot, or every
    /// later spec's colour lands on the wrong curve.
    @Test("A spec resolving to no series shifts nobody's colour")
    func brokenSpecDoesNotShiftColours() {
        let (store, id, calcId) = housesModel()
        let chart = ChartData(title: "Mixed", kind: .bar, series: [
            // Broken source — resolves to zero series.
            ChartSeriesSpec(name: "Gone", colorHex: "#ff0000",
                            source: .calculatorRows(componentId: "no-such-calc", keys: ["total"])),
            ChartSeriesSpec(name: "Total", colorHex: "#00ff00",
                            source: .calculatorRows(componentId: calcId, keys: ["total"])),
        ])
        let display = ChartResolver.displaySeries(chart, components: components(store, id))
        #expect(display.count == 1)
        #expect(display[0].series.name == "Total")
        // The green must not have been consumed by the dropped spec.
        #expect(display[0].colorHex == "#00ff00")
    }

    /// One house, so the linkedSweep resolves to exactly one curve.
    private func oneHouseModel() -> (MyAppStore, UUID, String) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "house", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        let id = myApp.id

        store.addComponent(kind: "tracker", name: "Houses", iconSystemName: "house", myAppId: id)
        store.setTracker(title: "Houses",
                         fields: [FieldDef(name: "name", type: .text), FieldDef(name: "price", type: .number)],
                         myAppId: id)
        store.addItem(["name": "Maple", "price": "100"], myAppId: id)
        let trackerId = components(store, id).first(where: {
            if case .tracker = $0.body { return true }; return false
        })!.id
        let refs = trackerItems(store, id, trackerId).map {
            ComponentItemRef(componentId: trackerId, itemId: $0.id)
        }

        store.addComponent(kind: "calculator", name: "Calc", iconSystemName: "function", myAppId: id)
        let calcId = components(store, id).first(where: {
            if case .calculator = $0.body { return true }; return false
        })!.id
        store.addCalcRow(key: "price", name: "Price",
                         kind: .linkedField(LinkedFieldSpec(ref: refs[0], fieldName: "price")), myAppId: id)
        store.addCalcRow(key: "year", name: "Year",
                         kind: .variable(value: 1, control: .slider(min: 1, max: 3, step: 1)), myAppId: id)
        store.addCalcRow(key: "total", name: "Total",
                         kind: .formula(expression: "price * year"), myAppId: id)
        store.addCalcRow(key: "curves", name: "Curve per house",
                         kind: .list(.linkedSweep(refs: refs, linkedRowKey: "price", variableKey: "year",
                                                  from: 1, to: 3, step: 1, targetKey: "total")), myAppId: id)
        return (store, id, calcId)
    }
}
