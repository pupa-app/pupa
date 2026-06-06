import Foundation
import Testing
@testable import PupaApp

/// Tests for the calculator component: Codable round-trip + legacy decode,
/// store mutators (add/patch/remove/setVariable + slug dedupe), and
/// `CalculatorResolver` integration across the mortgage + restaurant-share
/// scenarios, plus broken-ref and cycle handling.
@MainActor
@Suite("Calculator component")
struct CalculatorTests {

    private func freshStore() -> (MyAppStore, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "function", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.addComponent(kind: "calculator", name: "Calc", iconSystemName: "function", myAppId: myApp.id)
        return (store, myApp.id)
    }

    private func calc(_ store: MyAppStore, _ id: UUID) -> CalculatorData? {
        for comp in store.myApps.first(where: { $0.id == id })?.components ?? [] {
            if case .calculator(let c) = comp.body { return c }
        }
        return nil
    }

    private func components(_ store: MyAppStore, _ id: UUID) -> [Component] {
        store.myApps.first(where: { $0.id == id })?.components ?? []
    }

    // MARK: - Codec

    @Test("Round-trip Codable preserves all three row kinds")
    func roundTrip() throws {
        let original = CalculatorData(title: "Model", rows: [
            CalcRow(key: "principal", name: "Principal", unit: "$",
                    kind: .variable(value: 300_000, control: .slider(min: 0, max: 1_000_000, step: 1000))),
            CalcRow(key: "spend", name: "African spend",
                    kind: .aggregate(AggregateSpec(sourceComponentId: "tracker-1", fieldName: "amount", reduce: .sum, filter: ["cuisine": "African"]))),
            CalcRow(key: "share", name: "Share", unit: "%", format: "%.1f",
                    kind: .formula(expression: "spend / total * 100")),
        ])
        let data = try JSONEncoder().encode(CanvasApp.calculator(original))
        let decoded = try JSONDecoder().decode(CanvasApp.self, from: data)
        guard case .calculator(let restored) = decoded else {
            Issue.record("decoded as \(decoded.kindString) — expected calculator")
            return
        }
        #expect(restored.title == "Model")
        #expect(restored.rows.count == 3)
        #expect(restored.rows[0].kind == .variable(value: 300_000, control: .slider(min: 0, max: 1_000_000, step: 1000)))
        if case .aggregate(let spec) = restored.rows[1].kind {
            #expect(spec.filter == ["cuisine": "African"])
            #expect(spec.reduce == .sum)
        } else {
            Issue.record("row 1 should be aggregate")
        }
        #expect(restored.rows[2].kind == .formula(expression: "spend / total * 100"))
        #expect(restored.rows[2].unit == "%")
        #expect(restored.rows[2].format == "%.1f")
    }

    @Test("Legacy-ish JSON (missing optional fields) decodes with defaults")
    func legacyDecode() throws {
        // A row blob with no id / name / unit, a stepper control with no
        // step, and an aggregate with no filter — all should default.
        let json = """
        {
          "kind": "calculator",
          "data": {
            "title": "Legacy",
            "rows": [
              { "key": "rate", "kind": { "type": "variable", "value": 5, "control": { "type": "stepper" } } },
              { "key": "n", "kind": { "type": "aggregate", "aggregate": { "sourceComponentId": "tracker-1", "fieldName": "amt", "reduce": "count" } } }
            ]
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CanvasApp.self, from: json)
        guard case .calculator(let c) = decoded else {
            Issue.record("expected calculator")
            return
        }
        #expect(c.rows.count == 2)
        #expect(c.rows[0].name == "rate")       // name defaulted to key
        #expect(c.rows[0].kind == .variable(value: 5, control: .stepper(step: 1)))
        if case .aggregate(let spec) = c.rows[1].kind {
            #expect(spec.filter.isEmpty)
            #expect(spec.reduce == .count)
        } else {
            Issue.record("row 1 should be aggregate")
        }
    }

    // MARK: - Mutators

    @Test("addCalcRow slug-dedupes keys and returns the resolved key")
    func addAndDedupe() {
        let (store, id) = freshStore()
        let k1 = store.addCalcRow(name: "Monthly Spend", kind: .variable(value: 1, control: .plain), myAppId: id)
        let k2 = store.addCalcRow(name: "Monthly Spend", kind: .variable(value: 2, control: .plain), myAppId: id)
        #expect(k1 == "monthly_spend")
        #expect(k2 == "monthly_spend_2")
        #expect(calc(store, id)?.rows.count == 2)
    }

    @Test("patchCalcRow edits name without touching the key; removeCalcRow drops it")
    func patchRemove() {
        let (store, id) = freshStore()
        let key = store.addCalcRow(name: "Rate", kind: .variable(value: 1, control: .plain), myAppId: id)!
        var patch = MyAppStore.CalcRowPatch()
        patch.name = "Interest rate"
        patch.unit = "%"
        #expect(store.patchCalcRow(key: key, patch: patch, myAppId: id))
        let row = calc(store, id)?.rows.first
        #expect(row?.key == "rate")          // key immutable
        #expect(row?.name == "Interest rate")
        #expect(row?.unit == "%")
        #expect(store.removeCalcRow(key: key, myAppId: id))
        #expect(calc(store, id)?.rows.isEmpty == true)
        #expect(store.removeCalcRow(key: "nope", myAppId: id) == false)
    }

    @Test("setCalculatorVariable updates a variable value and is a no-op when unchanged")
    func setVariable() {
        let (store, id) = freshStore()
        let key = store.addCalcRow(name: "P", kind: .variable(value: 100, control: .slider(min: 0, max: 200, step: 1)), myAppId: id)!
        #expect(store.setCalculatorVariable(key: key, value: 150, myAppId: id))
        if case .variable(let v, let control)? = calc(store, id)?.rows.first?.kind {
            #expect(v == 150)
            #expect(control == .slider(min: 0, max: 200, step: 1)) // control preserved
        } else {
            Issue.record("expected a variable row")
        }
        #expect(store.setCalculatorVariable(key: key, value: 150, myAppId: id) == false) // unchanged
    }

    // MARK: - Resolver integration

    @Test("mortgage scenario: variable rows drive a formula row")
    func mortgageResolve() {
        let (store, id) = freshStore()
        store.addCalcRow(key: "principal", name: "Principal", kind: .variable(value: 300_000, control: .plain), myAppId: id)
        store.addCalcRow(key: "r", name: "Monthly rate", kind: .variable(value: 0.06 / 12, control: .plain), myAppId: id)
        store.addCalcRow(key: "n", name: "Payments", kind: .variable(value: 360, control: .plain), myAppId: id)
        store.addCalcRow(key: "payment", name: "Monthly payment",
                         kind: .formula(expression: "principal * r / (1 - (1+r)^(-n))"), myAppId: id)

        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        let payment = resolved.result(forKey: "payment")
        #expect(payment?.status == .ok)
        #expect((payment?.value ?? 0) > 1797 && (payment?.value ?? 0) < 1799)

        // Tuning the principal moves the downstream payment up.
        store.setCalculatorVariable(key: "principal", value: 600_000, myAppId: id)
        let after = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        #expect((after.result(forKey: "payment")?.value ?? 0) > 3500)
    }

    @Test("restaurant scenario: aggregates + share formula compute correctly")
    func restaurantShare() {
        let (store, id) = freshStore()
        // A source expense tracker.
        store.addComponent(kind: "tracker", name: "Expenses", iconSystemName: "list.bullet", myAppId: id)
        store.setTracker(title: "Expenses",
                         fields: [FieldDef(name: "amount", type: .number), FieldDef(name: "cuisine", type: .text)],
                         myAppId: id)
        store.addItem(["amount": "20", "cuisine": "African"], myAppId: id)
        store.addItem(["amount": "30", "cuisine": "African"], myAppId: id)
        store.addItem(["amount": "50", "cuisine": "Italian"], myAppId: id)
        let trackerId = store.myApps.first(where: { $0.id == id })!.components.first(where: {
            if case .tracker = $0.body { return true }; return false
        })!.id

        store.addCalcRow(key: "total", name: "Total",
                         kind: .aggregate(AggregateSpec(sourceComponentId: trackerId, fieldName: "amount", reduce: .sum)), myAppId: id)
        store.addCalcRow(key: "african", name: "African",
                         kind: .aggregate(AggregateSpec(sourceComponentId: trackerId, fieldName: "amount", reduce: .sum, filter: ["cuisine": "African"])), myAppId: id)
        store.addCalcRow(key: "african_share", name: "African share", unit: "%",
                         kind: .formula(expression: "african / total * 100"), myAppId: id)

        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        #expect(resolved.result(forKey: "total")?.value == 100)
        #expect(resolved.result(forKey: "african")?.value == 50)
        #expect(resolved.result(forKey: "african_share")?.value == 50)
    }

    @Test("deleting the source tracker yields brokenRef, not a crash")
    func brokenRef() {
        let (store, id) = freshStore()
        store.addComponent(kind: "tracker", name: "Expenses", iconSystemName: "list.bullet", myAppId: id)
        store.setTracker(title: "Expenses", fields: [FieldDef(name: "amount", type: .number)], myAppId: id)
        store.addItem(["amount": "20"], myAppId: id)
        let trackerId = store.myApps.first(where: { $0.id == id })!.components.first(where: {
            if case .tracker = $0.body { return true }; return false
        })!.id
        store.addCalcRow(key: "total", name: "Total",
                         kind: .aggregate(AggregateSpec(sourceComponentId: trackerId, fieldName: "amount", reduce: .sum)), myAppId: id)
        store.addCalcRow(key: "doubled", name: "Doubled", kind: .formula(expression: "total * 2"), myAppId: id)

        // Remove the source tracker.
        store.removeComponent(componentId: trackerId, myAppId: id)
        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        #expect(resolved.result(forKey: "total")?.status == .brokenRef)
        #expect(resolved.result(forKey: "total")?.value == nil)
        // The dependent formula propagates as brokenRef rather than crashing.
        #expect(resolved.result(forKey: "doubled")?.status == .brokenRef)
    }

    @Test("a formula cycle is flagged, acyclic rows still resolve")
    func cycle() {
        let (store, id) = freshStore()
        store.addCalcRow(key: "a", name: "A", kind: .formula(expression: "b + 1"), myAppId: id)
        store.addCalcRow(key: "b", name: "B", kind: .formula(expression: "a + 1"), myAppId: id)
        store.addCalcRow(key: "c", name: "C", kind: .variable(value: 42, control: .plain), myAppId: id)

        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        #expect(resolved.result(forKey: "a")?.status == .cycle)
        #expect(resolved.result(forKey: "b")?.status == .cycle)
        #expect(resolved.result(forKey: "c")?.value == 42) // unaffected
    }

    @Test("division by zero in a formula is flagged")
    func divByZero() {
        let (store, id) = freshStore()
        store.addCalcRow(key: "x", name: "X", kind: .variable(value: 0, control: .plain), myAppId: id)
        store.addCalcRow(key: "y", name: "Y", kind: .formula(expression: "1 / x"), myAppId: id)
        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        #expect(resolved.result(forKey: "y")?.status == .divisionByZero)
    }
}
