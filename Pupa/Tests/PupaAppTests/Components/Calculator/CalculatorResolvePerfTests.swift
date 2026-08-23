import Foundation
import Testing
@testable import PupaApp

/// Guards the resolve-cost invariants that keep a chart-linked calculator
/// interactive. A `list` row re-reads the scalar model once per sweep step
/// (and once per compared ref), so anything hoisted out of that loop must
/// stay hoisted — these tests fail if it creeps back in.
///
/// Deterministic by construction: they count parses rather than timing the
/// resolve, so they mean the same thing on a loaded machine.
@MainActor
@Suite("Calculator resolve cost")
struct CalculatorResolvePerfTests {

    /// A mortgage model: linked fields off a house tracker, a formula chain,
    /// and three list rows (a 4-house comparison plus two 30-step sweeps).
    /// Deliberately the heaviest shape a calculator takes — that is what makes
    /// it worth pinning the resolve cost against.
    private func mortgageModel() -> (CalculatorData, [Component]) {
        var items: [TrackerItem] = []
        for (i, name) in ["Maple St", "Oak Ave", "Pine Rd", "Cedar Ln"].enumerated() {
            items.append(TrackerItem(values: [
                "name": name,
                "price": "\(600_000 + i * 50_000)",
                "down_payment_pct": "20",
                "interest_rate": "6.5",
                "term_years": "30",
                "property_tax": "\(7000 + i * 500)",
                "hoa": "\(150 + i * 25)",
            ]))
        }
        let tracker = Component(
            id: "tracker-1", name: "Houses", iconSystemName: "house",
            body: .tracker(TrackerData(
                title: "Houses",
                fields: [
                    FieldDef(name: "name", type: .text),
                    FieldDef(name: "price", type: .number),
                    FieldDef(name: "down_payment_pct", type: .number),
                    FieldDef(name: "interest_rate", type: .number),
                    FieldDef(name: "term_years", type: .number),
                    FieldDef(name: "property_tax", type: .number),
                    FieldDef(name: "hoa", type: .number),
                ],
                items: items
            ))
        )
        let refs = items.map { ComponentItemRef(componentId: "tracker-1", itemId: $0.id) }
        func linked(_ field: String) -> CalcRowKind {
            .linkedField(LinkedFieldSpec(ref: refs[0], fieldName: field))
        }
        let rows: [CalcRow] = [
            CalcRow(key: "price", name: "Price", kind: linked("price")),
            CalcRow(key: "down_pct", name: "Down", kind: linked("down_payment_pct")),
            CalcRow(key: "rate_annual", name: "Rate", kind: linked("interest_rate")),
            CalcRow(key: "term_years", name: "Term", kind: linked("term_years")),
            CalcRow(key: "prop_tax_annual", name: "Tax", kind: linked("property_tax")),
            CalcRow(key: "hoa_monthly", name: "HOA", kind: linked("hoa")),
            CalcRow(key: "avg_price", name: "Average price",
                    kind: .aggregate(AggregateSpec(sourceComponentId: "tracker-1", fieldName: "price", reduce: .avg))),
            CalcRow(key: "principal", name: "Principal", kind: .formula(expression: "price * (1 - down_pct / 100)")),
            CalcRow(key: "down_amount", name: "Down amount", kind: .formula(expression: "price * down_pct / 100")),
            CalcRow(key: "r", name: "Monthly rate", kind: .formula(expression: "rate_annual / 100 / 12")),
            CalcRow(key: "n", name: "Payments", kind: .formula(expression: "term_years * 12")),
            CalcRow(key: "pi", name: "P&I", kind: .formula(expression: "principal * r * (1 + r)^n / ((1 + r)^n - 1)")),
            CalcRow(key: "monthly", name: "Monthly", kind: .formula(expression: "pi + prop_tax_annual / 12 + hoa_monthly")),
            CalcRow(key: "year", name: "Year", kind: .variable(value: 15, control: .slider(min: 1, max: 30, step: 1))),
            CalcRow(key: "appreciation_pct", name: "Appreciation", kind: .variable(value: 3, control: .slider(min: 0, max: 10, step: 0.5))),
            CalcRow(key: "months_paid", name: "Months paid", kind: .formula(expression: "min(year * 12, n)")),
            CalcRow(key: "home_value", name: "Home value", kind: .formula(expression: "price * (1 + appreciation_pct / 100)^year")),
            CalcRow(key: "loan_balance", name: "Owed", kind: .formula(expression: "principal * ((1 + r)^n - (1 + r)^months_paid) / ((1 + r)^n - 1)")),
            CalcRow(key: "own_wealth", name: "Own net worth", kind: .formula(expression: "home_value - loan_balance")),
            CalcRow(key: "compare", name: "Monthly by house",
                    kind: .list(.linkedCompare(refs: refs, targetKey: "monthly", linkedRowKey: "price"))),
            CalcRow(key: "own_curve", name: "Own curve",
                    kind: .list(.sweep(variableKey: "year", from: 1, to: 30, step: 1, targetKey: "own_wealth"))),
            CalcRow(key: "linked_curves", name: "Curve per house",
                    kind: .list(.linkedSweep(refs: refs, linkedRowKey: "price", variableKey: "year",
                                             from: 1, to: 30, step: 1, targetKey: "own_wealth"))),
        ]
        let data = CalculatorData(title: "Mortgage Model", rows: rows)
        let calc = Component(
            id: "calculator-1", name: "Mortgage Model", iconSystemName: "function",
            body: .calculator(data)
        )
        return (data, [tracker, calc])
    }

    /// The number of `formula` rows in `mortgageModel` — the parse budget for
    /// one resolve, no matter how many steps the sweeps take.
    private let formulaCount = 10

    @Test("A resolve parses each formula exactly once, however many sweep steps it drives")
    func parsesEachFormulaOncePerResolve() {
        let (data, components) = mortgageModel()
        CalculatorResolver.parseCountForTesting = 0
        _ = CalculatorResolver.resolve(data, components: components)
        // Two 30-step sweeps plus a 4-ref compare plus a 4-ref linked sweep
        // re-read the model ~150 times. Re-parsing per read would be ~1800.
        #expect(CalculatorResolver.parseCountForTesting == formulaCount)
    }

    @Test("Disabling list rows does not change the parse budget")
    func parseBudgetIndependentOfLists() {
        let (data, components) = mortgageModel()
        CalculatorResolver.parseCountForTesting = 0
        _ = CalculatorResolver.resolve(data, components: components, computeLists: false)
        #expect(CalculatorResolver.parseCountForTesting == formulaCount)
    }

    /// The pass-1 leaves re-scan every aggregate's source tracker, so they may
    /// scale with the number of *compared refs* — never with sweep steps.
    @Test("Pass-1 leaves are built once per compared ref, not once per sweep step")
    func baseIsBuiltPerRefNotPerStep() {
        let (data, components) = mortgageModel()
        CalculatorResolver.baseBuildCountForTesting = 0
        _ = CalculatorResolver.resolve(data, components: components)
        // 1 for the model itself + 4 linkedCompare refs + 4 linkedSweep refs.
        // The 30 steps each of those curves takes contribute nothing: a swept
        // value cannot reach a leaf. Rebuilding per step would make this 150+.
        #expect(CalculatorResolver.baseBuildCountForTesting == 9)
    }

    @Test("Widening a sweep's range does not build more pass-1 leaves")
    func baseCountIsIndependentOfSweepLength() {
        var (data, components) = mortgageModel()
        let idx = data.rows.firstIndex(where: { $0.key == "own_curve" })!

        CalculatorResolver.baseBuildCountForTesting = 0
        _ = CalculatorResolver.resolve(data, components: components)
        let coarse = CalculatorResolver.baseBuildCountForTesting

        // Same sweep, four times as many points.
        data.rows[idx].kind = .list(.sweep(variableKey: "year", from: 1, to: 30, step: 0.25, targetKey: "own_wealth"))
        CalculatorResolver.baseBuildCountForTesting = 0
        let resolved = CalculatorResolver.resolve(data, components: components)
        let fine = CalculatorResolver.baseBuildCountForTesting

        #expect(resolved.result(forKey: "own_curve")?.list?.count == 117)
        #expect(fine == coarse)
    }

    // MARK: - Results are unchanged by the staged resolve

    @Test("Sweep still varies the swept variable and holds the rest fixed")
    func sweepValuesAreCorrect() {
        let (data, components) = mortgageModel()
        let resolved = CalculatorResolver.resolve(data, components: components)
        let points = resolved.result(forKey: "own_curve")?.list ?? []
        #expect(points.count == 30)
        #expect(points.first?.x == 1)
        #expect(points.last?.x == 30)
        // Equity grows monotonically over the projection.
        let ys = points.map(\.y)
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 })

        // The swept row's own displayed value is the spec value, not the last
        // step — the sweep must not leak back into the scalar model.
        #expect(resolved.result(forKey: "year")?.value == 15)
    }

    @Test("Sweep reads the same target the scalar model reports at that value")
    func sweepAgreesWithScalarModel() {
        var (data, components) = mortgageModel()
        let resolved = CalculatorResolver.resolve(data, components: components)
        let atFifteen = resolved.result(forKey: "own_curve")?.list?.first(where: { $0.x == 15 })?.y

        // Pin `year` to 15 directly and resolve — same number.
        let idx = data.rows.firstIndex(where: { $0.key == "year" })!
        data.rows[idx].kind = .variable(value: 15, control: .slider(min: 1, max: 30, step: 1))
        let direct = CalculatorResolver.resolve(data, components: components).result(forKey: "own_wealth")?.value

        #expect(atFifteen != nil)
        #expect(direct != nil)
        #expect(abs(atFifteen! - direct!) < 0.000_1)
    }

    @Test("linkedCompare yields one point per house, each with that house's numbers")
    func linkedCompareValuesAreCorrect() {
        let (data, components) = mortgageModel()
        let resolved = CalculatorResolver.resolve(data, components: components)
        let points = resolved.result(forKey: "compare")?.list ?? []
        #expect(points.map(\.label) == ["Maple St", "Oak Ave", "Pine Rd", "Cedar Ln"])
        // Pricier houses cost more per month, so the series is increasing.
        let ys = points.map(\.y)
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 })
        // The first house is the one the rows are actually bound to, so its
        // compared value equals the live scalar row.
        #expect(abs(points[0].y - (resolved.result(forKey: "monthly")?.value ?? 0)) < 0.000_1)
    }

    @Test("linkedSweep yields one full curve per house")
    func linkedSweepValuesAreCorrect() {
        let (data, components) = mortgageModel()
        let resolved = CalculatorResolver.resolve(data, components: components)
        let series = resolved.result(forKey: "linked_curves")?.series ?? []
        #expect(series.count == 4)
        #expect(series.map(\.name) == ["Maple St", "Oak Ave", "Pine Rd", "Cedar Ln"])
        #expect(series.allSatisfy { $0.points.count == 30 })
        // The anchor house's curve matches the standalone sweep of the same target.
        let standalone = resolved.result(forKey: "own_curve")?.list ?? []
        for (a, b) in zip(series[0].points, standalone) {
            #expect(abs(a.y - b.y) < 0.000_1)
        }
    }

    @Test("Aggregates survive a sweep unchanged — the swept value can't reach them")
    func aggregateIsStableAcrossSweep() {
        let (data, components) = mortgageModel()
        let resolved = CalculatorResolver.resolve(data, components: components)
        // avg of 600k, 650k, 700k, 750k
        #expect(resolved.result(forKey: "avg_price")?.value == 675_000)
        #expect(resolved.result(forKey: "avg_price")?.status == .ok)
    }

    // MARK: - Mis-keyed models must stay loud

    /// A duplicate key that puts a formula ahead of the swept variable used to
    /// be reported as `brokenRef`. Matching on *any* row with the key instead
    /// of the first one turned that into a silently flat curve — a wrong chart
    /// that looks right, which is strictly worse than a visible error.
    @Test("A sweep whose key resolves to a formula first reports brokenRef, not a flat curve")
    func sweptKeyShadowedByFormulaIsBroken() {
        let data = CalculatorData(title: "Dup", rows: [
            CalcRow(key: "x", name: "X formula", kind: .formula(expression: "2 + 2")),
            CalcRow(key: "x", name: "X variable", kind: .variable(value: 1, control: .slider(min: 1, max: 3, step: 1))),
            CalcRow(key: "y", name: "Y", kind: .formula(expression: "x * 2")),
            CalcRow(key: "curve", name: "Curve",
                    kind: .list(.sweep(variableKey: "x", from: 1, to: 3, step: 1, targetKey: "y"))),
        ])
        let result = CalculatorResolver.resolve(data, components: []).result(forKey: "curve")
        #expect(result?.status == .brokenRef)
        #expect(result?.list == nil)
    }

    @Test("A sweep over a genuine variable row still resolves when a later duplicate exists")
    func sweptKeyVariableFirstStillSweeps() {
        let data = CalculatorData(title: "Dup", rows: [
            CalcRow(key: "x", name: "X variable", kind: .variable(value: 1, control: .slider(min: 1, max: 3, step: 1))),
            CalcRow(key: "y", name: "Y", kind: .formula(expression: "x * 2")),
            CalcRow(key: "curve", name: "Curve",
                    kind: .list(.sweep(variableKey: "x", from: 1, to: 3, step: 1, targetKey: "y"))),
        ])
        let result = CalculatorResolver.resolve(data, components: []).result(forKey: "curve")
        #expect(result?.status == .ok)
        #expect(result?.list?.map(\.y) == [2, 4, 6])
    }

    /// The swept value is substituted after the pass-1 leaves, so it wins over
    /// every duplicate — where the row array used to be mutated in place and
    /// last-write-wins pinned the curve flat.
    @Test("Two variable rows sharing the swept key still sweep, rather than going flat")
    func duplicateVariableKeyStillSweeps() {
        let data = CalculatorData(title: "Dup", rows: [
            CalcRow(key: "x", name: "X one", kind: .variable(value: 1, control: .slider(min: 1, max: 3, step: 1))),
            CalcRow(key: "x", name: "X two", kind: .variable(value: 7, control: .plain)),
            CalcRow(key: "y", name: "Y", kind: .formula(expression: "x * 2")),
            CalcRow(key: "curve", name: "Curve",
                    kind: .list(.sweep(variableKey: "x", from: 1, to: 3, step: 1, targetKey: "y"))),
        ])
        let result = CalculatorResolver.resolve(data, components: []).result(forKey: "curve")
        #expect(result?.status == .ok)
        #expect(result?.list?.map(\.y) == [2, 4, 6])
        // The scalar row itself still reports last-write-wins, unchanged.
        #expect(CalculatorResolver.resolve(data, components: []).result(forKey: "x")?.value == 7)
    }

    @Test("A compare anchor shadowed by a non-linked row reports brokenRef")
    func compareAnchorShadowedIsBroken() {
        let ref = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        let data = CalculatorData(title: "Dup", rows: [
            CalcRow(key: "price", name: "Price variable", kind: .variable(value: 1, control: .plain)),
            CalcRow(key: "price", name: "Price linked", kind: .linkedField(LinkedFieldSpec(ref: ref, fieldName: "price"))),
            CalcRow(key: "cmp", name: "Compare",
                    kind: .list(.linkedCompare(refs: [ref], targetKey: "price", linkedRowKey: "price"))),
        ])
        let result = CalculatorResolver.resolve(data, components: []).result(forKey: "cmp")
        #expect(result?.status == .brokenRef)
    }

    // MARK: - Spec errors report the same status nested as standalone

    @Test("An unusable range is nonNumeric in a sweep and in a linkedSweep alike")
    func badRangeStatusIsConsistent() {
        let ref = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        let rows: [CalcRow] = [
            CalcRow(key: "price", name: "Price", kind: .linkedField(LinkedFieldSpec(ref: ref, fieldName: "price"))),
            CalcRow(key: "x", name: "X", kind: .variable(value: 1, control: .plain)),
            CalcRow(key: "y", name: "Y", kind: .formula(expression: "x * 2")),
            // step: 0 — an unusable range, not a bad reference.
            CalcRow(key: "flat", name: "Flat",
                    kind: .list(.sweep(variableKey: "x", from: 1, to: 3, step: 0, targetKey: "y"))),
            CalcRow(key: "flat_linked", name: "Flat linked",
                    kind: .list(.linkedSweep(refs: [ref], linkedRowKey: "price", variableKey: "x",
                                             from: 1, to: 3, step: 0, targetKey: "y"))),
        ]
        let resolved = CalculatorResolver.resolve(CalculatorData(title: "T", rows: rows), components: [])
        #expect(resolved.result(forKey: "flat")?.status == .nonNumeric)
        #expect(resolved.result(forKey: "flat_linked")?.status == .nonNumeric)
    }

    @Test("An unknown target key is brokenRef in a sweep and in a linkedSweep alike")
    func unknownTargetStatusIsConsistent() {
        let ref = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        let rows: [CalcRow] = [
            CalcRow(key: "price", name: "Price", kind: .linkedField(LinkedFieldSpec(ref: ref, fieldName: "price"))),
            CalcRow(key: "x", name: "X", kind: .variable(value: 1, control: .plain)),
            CalcRow(key: "gone", name: "Gone",
                    kind: .list(.sweep(variableKey: "x", from: 1, to: 3, step: 1, targetKey: "nope"))),
            CalcRow(key: "gone_linked", name: "Gone linked",
                    kind: .list(.linkedSweep(refs: [ref], linkedRowKey: "price", variableKey: "x",
                                             from: 1, to: 3, step: 1, targetKey: "nope"))),
        ]
        let resolved = CalculatorResolver.resolve(CalculatorData(title: "T", rows: rows), components: [])
        #expect(resolved.result(forKey: "gone")?.status == .brokenRef)
        #expect(resolved.result(forKey: "gone_linked")?.status == .brokenRef)
    }
}
