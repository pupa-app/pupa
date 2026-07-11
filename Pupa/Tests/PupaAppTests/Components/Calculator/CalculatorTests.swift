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

    @Test("list sweep varies one variable, holds others, reads the target each step")
    func listSweep() {
        let (store, id) = freshStore()
        store.addCalcRow(key: "principal", name: "Principal", kind: .variable(value: 1000, control: .plain), myAppId: id)
        store.addCalcRow(key: "rate", name: "Rate", kind: .variable(value: 0, control: .plain), myAppId: id)
        // interest = principal * rate
        store.addCalcRow(key: "interest", name: "Interest", kind: .formula(expression: "principal * rate"), myAppId: id)
        // Sweep rate 0 → 0.2 step 0.1, read interest. principal stays 1000.
        store.addCalcRow(key: "curve", name: "Curve",
                         kind: .list(.sweep(variableKey: "rate", from: 0, to: 0.2, step: 0.1, targetKey: "interest")), myAppId: id)

        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        let list = resolved.result(forKey: "curve")?.list
        #expect(list?.count == 3)
        let ys = list?.map(\.y) ?? []
        #expect(ys[0] == 0)
        #expect(abs(ys[1] - 100) < 1e-6)   // 1000 * 0.1
        #expect(abs(ys[2] - 200) < 1e-6)   // 1000 * 0.2
        // Sweeping rate must NOT mutate the stored variable (still 0).
        if case .variable(let v, _)? = calc(store, id)?.rows.first(where: { $0.key == "rate" })?.kind {
            #expect(v == 0)
        } else { Issue.record("rate should still be a variable") }
        // List rows are terminal — carry no scalar value.
        #expect(resolved.result(forKey: "curve")?.value == nil)
    }

    @Test("a scalar formula referencing a list key resolves to brokenRef")
    func formulaOnListIsBroken() {
        let (store, id) = freshStore()
        store.addCalcRow(key: "x", name: "X", kind: .variable(value: 1, control: .plain), myAppId: id)
        store.addCalcRow(key: "lst", name: "List",
                         kind: .list(.sweep(variableKey: "x", from: 1, to: 3, step: 1, targetKey: "x")), myAppId: id)
        store.addCalcRow(key: "bad", name: "Bad", kind: .formula(expression: "lst + 1"), myAppId: id)
        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        #expect(resolved.result(forKey: "bad")?.status == .brokenRef)
    }

    @Test("list trackerColumn pulls a raw per-item array")
    func listTrackerColumn() {
        let (store, id) = freshStore()
        store.addComponent(kind: "tracker", name: "Readings", iconSystemName: "list.bullet", myAppId: id)
        store.setTracker(title: "Readings", fields: [FieldDef(name: "value", type: .number)], myAppId: id)
        store.addItem(["value": "5"], myAppId: id)
        store.addItem(["value": "8"], myAppId: id)
        store.addItem(["value": "x"], myAppId: id)   // non-numeric → skipped
        let trackerId = store.myApps.first(where: { $0.id == id })!.components.first(where: {
            if case .tracker = $0.body { return true }; return false
        })!.id
        store.addCalcRow(key: "col", name: "Col",
                         kind: .list(.trackerColumn(sourceComponentId: trackerId, valueField: "value", labelField: nil, filter: [:])), myAppId: id)
        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        #expect(resolved.result(forKey: "col")?.list?.map(\.y) == [5, 8])
    }

    @Test("division by zero in a formula is flagged")
    func divByZero() {
        let (store, id) = freshStore()
        store.addCalcRow(key: "x", name: "X", kind: .variable(value: 0, control: .plain), myAppId: id)
        store.addCalcRow(key: "y", name: "Y", kind: .formula(expression: "1 / x"), myAppId: id)
        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        #expect(resolved.result(forKey: "y")?.status == .divisionByZero)
    }

    @Test("header row round-trips via Codable and is skipped by the resolver")
    func headerRow() throws {
        let data = CalculatorData(title: "Model", rows: [
            CalcRow(key: "sec_inputs", name: "Inputs", kind: .header),
            CalcRow(key: "rate", name: "Rate", kind: .variable(value: 5, control: .plain)),
            CalcRow(key: "sec_results", name: "Results", kind: .header),
            CalcRow(key: "result", name: "Result", kind: .formula(expression: "rate * 2")),
        ])
        // Codec round-trip.
        let json = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(CalculatorData.self, from: json)
        #expect(decoded.rows.count == 4)
        if case .header = decoded.rows[0].kind { } else { Issue.record("row[0] not header") }
        if case .header = decoded.rows[2].kind { } else { Issue.record("row[2] not header") }

        // Resolver: header produces no result; formula downstream still works.
        let resolved = CalculatorResolver.resolve(data, components: [])
        #expect(resolved.result(forKey: "sec_inputs") == nil)
        #expect(resolved.result(forKey: "sec_results") == nil)
        #expect(resolved.result(forKey: "result")?.value == 10)
    }

    // MARK: - Linked-field rows

    /// Seed a houses tracker with `price` / `rate` fields; return (storeId,
    /// trackerComponentId, [itemIds]).
    private func houses(_ store: MyAppStore, _ id: UUID, _ rows: [[String: String]]) -> (String, [UUID]) {
        store.addComponent(kind: "tracker", name: "Houses", iconSystemName: "house", myAppId: id)
        store.setTracker(title: "Houses",
                         fields: [FieldDef(name: "name", type: .text), FieldDef(name: "price", type: .number), FieldDef(name: "rate", type: .number)],
                         myAppId: id)
        var ids: [UUID] = []
        for r in rows { if let itemId = store.addItem(r, myAppId: id) { ids.append(itemId) } }
        let trackerId = store.myApps.first(where: { $0.id == id })!.components.first(where: {
            if case .tracker = $0.body { return true }; return false
        })!.id
        return (trackerId, ids)
    }

    @Test("linkedField pulls a numeric field off the linked item; a formula reads it")
    func linkedFieldResolves() {
        let (store, id) = freshStore()
        let (trackerId, ids) = houses(store, id, [["name": "A", "price": "500000", "rate": "6.5"]])
        store.addCalcRow(key: "price", name: "Price",
                         kind: .linkedField(LinkedFieldSpec(ref: ComponentItemRef(componentId: trackerId, itemId: ids[0]), fieldName: "price")), myAppId: id)
        store.addCalcRow(key: "half", name: "Half", kind: .formula(expression: "price / 2"), myAppId: id)

        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        #expect(resolved.result(forKey: "price")?.value == 500000)
        #expect(resolved.result(forKey: "half")?.value == 250000)
    }

    @Test("linkedField with no ref is brokenRef and poisons dependents")
    func linkedFieldUnlinked() {
        let (store, id) = freshStore()
        store.addCalcRow(key: "price", name: "Price",
                         kind: .linkedField(LinkedFieldSpec(ref: nil, fieldName: "price")), myAppId: id)
        store.addCalcRow(key: "half", name: "Half", kind: .formula(expression: "price / 2"), myAppId: id)
        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        #expect(resolved.result(forKey: "price")?.status == .brokenRef)
        #expect(resolved.result(forKey: "price")?.value == nil)
        #expect(resolved.result(forKey: "half")?.status == .brokenRef)
    }

    @Test("linkedField on a non-numeric field is nonNumeric")
    func linkedFieldNonNumeric() {
        let (store, id) = freshStore()
        let (trackerId, ids) = houses(store, id, [["name": "A", "price": "500000"]])
        store.addCalcRow(key: "label", name: "Label",
                         kind: .linkedField(LinkedFieldSpec(ref: ComponentItemRef(componentId: trackerId, itemId: ids[0]), fieldName: "name")), myAppId: id)
        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        #expect(resolved.result(forKey: "label")?.status == .nonNumeric)
    }

    @Test("setCalcRowLinkedRef swaps the linked item and re-runs the model")
    func linkedFieldSwap() {
        let (store, id) = freshStore()
        let (trackerId, ids) = houses(store, id, [
            ["name": "A", "price": "500000"],
            ["name": "B", "price": "400000"],
        ])
        store.addCalcRow(key: "price", name: "Price",
                         kind: .linkedField(LinkedFieldSpec(ref: ComponentItemRef(componentId: trackerId, itemId: ids[0]), fieldName: "price")), myAppId: id)
        #expect(CalculatorResolver.resolve(calc(store, id)!, components: components(store, id)).result(forKey: "price")?.value == 500000)
        // Swap to house B.
        #expect(store.setCalcRowLinkedRef(key: "price", ref: ComponentItemRef(componentId: trackerId, itemId: ids[1]), myAppId: id))
        #expect(CalculatorResolver.resolve(calc(store, id)!, components: components(store, id)).result(forKey: "price")?.value == 400000)
    }

    @Test("linkedCompare compares a set of houses on a target formula; swaps all shared-ref rows per house")
    func linkedCompare() {
        let (store, id) = freshStore()
        let (trackerId, ids) = houses(store, id, [
            ["name": "A", "price": "500000", "rate": "6"],
            ["name": "B", "price": "400000", "rate": "6"],
            ["name": "C", "price": "300000", "rate": "6"],
        ])
        func ref(_ i: Int) -> ComponentItemRef { ComponentItemRef(componentId: trackerId, itemId: ids[i]) }
        // Two linkedField rows on the SAME (house A) ref so both follow the swap.
        store.addCalcRow(key: "price", name: "Price", kind: .linkedField(LinkedFieldSpec(ref: ref(0), fieldName: "price")), myAppId: id)
        store.addCalcRow(key: "rate", name: "Rate", kind: .linkedField(LinkedFieldSpec(ref: ref(0), fieldName: "rate")), myAppId: id)
        // metric = price + rate (rate is constant 6 here, so metric tracks price).
        store.addCalcRow(key: "metric", name: "Metric", kind: .formula(expression: "price + rate"), myAppId: id)
        store.addCalcRow(key: "compare", name: "Compare",
                         kind: .list(.linkedCompare(refs: [ref(0), ref(1), ref(2)], targetKey: "metric", linkedRowKey: "price")), myAppId: id)

        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        let list = resolved.result(forKey: "compare")?.list
        #expect(list?.count == 3)
        #expect(list?.map(\.y) == [500006, 400006, 300006])
        #expect(list?.map(\.label) == ["A", "B", "C"])
        // Terminal list row carries no scalar value.
        #expect(resolved.result(forKey: "compare")?.value == nil)
    }

    @Test("deleting a linked house clears the linkedField ref and shrinks the compare set")
    func linkedFieldCascade() {
        let (store, id) = freshStore()
        let (trackerId, ids) = houses(store, id, [
            ["name": "A", "price": "500000"],
            ["name": "B", "price": "400000"],
        ])
        func ref(_ i: Int) -> ComponentItemRef { ComponentItemRef(componentId: trackerId, itemId: ids[i]) }
        store.addCalcRow(key: "price", name: "Price", kind: .linkedField(LinkedFieldSpec(ref: ref(0), fieldName: "price")), myAppId: id)
        store.addCalcRow(key: "compare", name: "Compare",
                         kind: .list(.linkedCompare(refs: [ref(0), ref(1)], targetKey: "price", linkedRowKey: "price")), myAppId: id)

        // Delete house A.
        store.removeItem(id: ids[0], myAppId: id, componentId: trackerId)

        let data = calc(store, id)!
        if case .linkedField(let spec) = data.rows.first(where: { $0.key == "price" })!.kind {
            #expect(spec.ref == nil)                       // cleared
        } else { Issue.record("price row should be linkedField") }
        if case .list(.linkedCompare(let refs, _, _)) = data.rows.first(where: { $0.key == "compare" })!.kind {
            #expect(refs == [ref(1)])                      // A dropped, B kept
        } else { Issue.record("compare row should be linkedCompare") }
    }

    @Test("linkedField + linkedCompare round-trip via Codable")
    func linkedRoundTrip() throws {
        let ref = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        let original = CalculatorData(title: "M", rows: [
            CalcRow(key: "price", name: "Price", kind: .linkedField(LinkedFieldSpec(ref: ref, fieldName: "price"))),
            CalcRow(key: "cmp", name: "Cmp", kind: .list(.linkedCompare(refs: [ref], targetKey: "price", linkedRowKey: "price"))),
        ])
        let json = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CalculatorData.self, from: json)
        #expect(decoded.rows[0].kind == .linkedField(LinkedFieldSpec(ref: ref, fieldName: "price")))
        #expect(decoded.rows[1].kind == .list(.linkedCompare(refs: [ref], targetKey: "price", linkedRowKey: "price")))
    }

    @Test("linkedSweep resolves one swept CURVE per linked ref")
    func linkedSweepResolvesCurvePerRef() {
        let (store, id) = freshStore()
        let (trackerId, ids) = houses(store, id, [
            ["name": "A", "price": "500000", "rate": "6"],
            ["name": "B", "price": "400000", "rate": "6"],
            ["name": "C", "price": "300000", "rate": "6"],
        ])
        func ref(_ i: Int) -> ComponentItemRef { ComponentItemRef(componentId: trackerId, itemId: ids[i]) }
        // Two linked rows on house A, a sweep variable `t`, a target formula.
        store.addCalcRow(key: "price", name: "Price", kind: .linkedField(LinkedFieldSpec(ref: ref(0), fieldName: "price")), myAppId: id)
        store.addCalcRow(key: "rate", name: "Rate", kind: .linkedField(LinkedFieldSpec(ref: ref(0), fieldName: "rate")), myAppId: id)
        store.addCalcRow(key: "t", name: "T", kind: .variable(value: 1, control: .plain), myAppId: id)
        // target = price * t (so each house's curve scales with its price).
        store.addCalcRow(key: "target", name: "Target", kind: .formula(expression: "price * t"), myAppId: id)
        store.addCalcRow(key: "curve_by_house", name: "By house",
                         kind: .list(.linkedSweep(refs: [ref(0), ref(1), ref(2)], linkedRowKey: "price",
                                                  variableKey: "t", from: 1, to: 3, step: 1, targetKey: "target")), myAppId: id)

        let resolved = CalculatorResolver.resolve(calc(store, id)!, components: components(store, id))
        let series = resolved.result(forKey: "curve_by_house")?.series
        #expect(series?.count == 3)                          // one curve per house
        #expect(series?.allSatisfy { $0.points.count == 3 } == true)  // t = 1,2,3
        #expect(series?.map(\.name) == ["A", "B", "C"])
        // House A: target = 500000 * t → 500000, 1000000, 1500000.
        #expect(series?.first?.points.map(\.y) == [500000, 1000000, 1500000])
        // A linkedSweep row carries no scalar value and no flat `list`.
        #expect(resolved.result(forKey: "curve_by_house")?.value == nil)
        #expect(resolved.result(forKey: "curve_by_house")?.list == nil)
    }

    @Test("linkedSweep round-trips via Codable")
    func linkedSweepRoundTrip() throws {
        let ref = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        let spec = CalcListSpec.linkedSweep(refs: [ref], linkedRowKey: "price",
                                            variableKey: "year", from: 1, to: 30, step: 1, targetKey: "net")
        let original = CalculatorData(title: "M", rows: [CalcRow(key: "s", name: "S", kind: .list(spec))])
        let json = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CalculatorData.self, from: json)
        #expect(decoded.rows[0].kind == .list(spec))
    }

    @Test("setAllCalcRowLinks repoints every linkedField row at one item in a single call")
    func setAllCalcRowLinks() {
        let (store, id) = freshStore()
        let (trackerId, ids) = houses(store, id, [
            ["name": "A", "price": "500000"],
            ["name": "B", "price": "400000"],
        ])
        func ref(_ i: Int) -> ComponentItemRef { ComponentItemRef(componentId: trackerId, itemId: ids[i]) }
        store.addCalcRow(key: "price", name: "Price", kind: .linkedField(LinkedFieldSpec(ref: ref(0), fieldName: "price")), myAppId: id)
        store.addCalcRow(key: "rate", name: "Rate", kind: .linkedField(LinkedFieldSpec(ref: ref(0), fieldName: "rate")), myAppId: id)

        let n = store.setAllCalcRowLinks(to: ref(1), myAppId: id)
        #expect(n == 2)                                       // both rows repointed
        let data = calc(store, id)!
        for key in ["price", "rate"] {
            if case .linkedField(let s) = data.rows.first(where: { $0.key == key })!.kind {
                #expect(s.ref == ref(1))
            } else { Issue.record("\(key) should be linkedField") }
        }
        // Idempotent: a second call to the same item repoints nothing.
        #expect(store.setAllCalcRowLinks(to: ref(1), myAppId: id) == 0)
    }
}
