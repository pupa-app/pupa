import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Pins `patchCalcRows` validation: a patch that cannot take effect must
/// report `ok:false` rather than a silent no-op with `ok:true`. Validation
/// runs over every entry before anything is written, so a rejected call
/// leaves the calculator untouched.
@MainActor
@Suite("patchCalcRows validation")
struct CalcRowPatchValidationTests {

    private func makeStore() -> (store: MiniAppStore, miniAppId: UUID) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApp = MiniApp(name: "T", iconSystemName: "function", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([miniApp], miniApp.id))
        store.addComponent(kind: "calculator", name: "Calc", iconSystemName: "function", miniAppId: miniApp.id)
        return (store, miniApp.id)
    }

    private func calc(_ store: MiniAppStore, _ id: UUID) -> CalculatorData? {
        for comp in store.miniApps.first(where: { $0.id == id })?.components ?? [] {
            if case .calculator(let c) = comp.body { return c }
        }
        return nil
    }

    /// A calculator with one slider variable (`rate`) and one formula (`out`).
    private func seed(_ registry: ToolRegistry) async throws {
        guard let render = registry.resolve("renderCalculator") else {
            Issue.record("renderCalculator not registered"); return
        }
        _ = try await render.handler(.object([
            "title": .string("Model"),
            "rows": .array([
                .object([
                    "key": .string("rate"),
                    "name": .string("Rate"),
                    "kind": .string("variable"),
                    "value": .double(5),
                    "control": .object([
                        "type": .string("slider"),
                        "min": .double(2), "max": .double(15), "step": .double(0.5),
                    ]),
                ]),
                .object([
                    "key": .string("out"),
                    "name": .string("Out"),
                    "kind": .string("formula"),
                    "expression": .string("rate * 2"),
                ]),
            ]),
        ]))
    }

    private func patch(_ registry: ToolRegistry, _ patches: [AnyJSON]) async throws -> AnyJSON {
        guard let tool = registry.resolve("patchCalcRows") else {
            Issue.record("patchCalcRows not registered")
            return .object([:])
        }
        return try await tool.handler(.object(["patches": .array(patches)]))
    }

    private func rate(_ store: MiniAppStore, _ miniAppId: UUID) -> CalcRow? {
        calc(store, miniAppId)?.rows.first { $0.key == "rate" }
    }

    // MARK: - The regression this suite exists for

    @Test("A kind-specific field without `kind` is rejected, not silently ignored")
    func valueWithoutKind_isRejected() async throws {
        let (store, miniAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMiniAppTools(on: registry, store: store, miniAppId: miniAppId)
        try await seed(registry)

        let result = try await patch(registry, [
            .object(["key": .string("rate"), "patch": .object(["value": .double(7)])]),
        ])

        #expect(result["ok"]?.boolValue == false)
        let error = result["errors"]?.arrayValue?.first?["error"]?.stringValue ?? ""
        #expect(error.contains("kind"))
        // Row untouched — still 5, still a slider.
        guard case .variable(let value, let control)? = rate(store, miniAppId)?.kind else {
            Issue.record("rate is no longer a variable"); return
        }
        #expect(value == 5)
        guard case .slider = control else {
            Issue.record("slider was demoted to \(control)"); return
        }
    }

    @Test("Every kind-only field is rejected when `kind` is absent")
    func everyKindOnlyField_isRejected() async throws {
        let (store, miniAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMiniAppTools(on: registry, store: store, miniAppId: miniAppId)
        try await seed(registry)

        for field in ["value", "control", "expression", "aggregate", "list", "linkedField"] {
            let result = try await patch(registry, [
                .object(["key": .string("rate"), "patch": .object([field: .object([:])])]),
            ])
            #expect(result["ok"]?.boolValue == false, "\(field) without kind should fail")
        }
    }

    // MARK: - Other silent failures

    @Test("An unknown row key is reported instead of quietly skipped")
    func unknownKey_isReported() async throws {
        let (store, miniAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMiniAppTools(on: registry, store: store, miniAppId: miniAppId)
        try await seed(registry)

        let result = try await patch(registry, [
            .object(["key": .string("nope"), "patch": .object(["name": .string("X")])]),
        ])
        #expect(result["ok"]?.boolValue == false)
        #expect(result["errors"]?.arrayValue?.first?["key"]?.stringValue == "nope")
    }

    @Test("An entry with no `key` is reported")
    func missingKey_isReported() async throws {
        let (store, miniAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMiniAppTools(on: registry, store: store, miniAppId: miniAppId)
        try await seed(registry)

        let result = try await patch(registry, [.object(["patch": .object(["name": .string("X")])])])
        #expect(result["ok"]?.boolValue == false)
    }

    @Test("A patch with no recognised field is reported")
    func emptyPatch_isReported() async throws {
        let (store, miniAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMiniAppTools(on: registry, store: store, miniAppId: miniAppId)
        try await seed(registry)

        let result = try await patch(registry, [
            .object(["key": .string("rate"), "patch": .object([:])]),
        ])
        #expect(result["ok"]?.boolValue == false)
    }

    @Test("An unparseable `kind` is reported rather than dropped")
    func badKind_isReported() async throws {
        let (store, miniAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMiniAppTools(on: registry, store: store, miniAppId: miniAppId)
        try await seed(registry)

        let result = try await patch(registry, [
            .object(["key": .string("rate"), "patch": .object(["kind": .string("bogus")])]),
        ])
        #expect(result["ok"]?.boolValue == false)
    }

    // MARK: - Validation is all-or-nothing

    @Test("One bad entry rejects the whole batch — no partial write")
    func batchIsAtomic() async throws {
        let (store, miniAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMiniAppTools(on: registry, store: store, miniAppId: miniAppId)
        try await seed(registry)

        let result = try await patch(registry, [
            .object(["key": .string("out"), "patch": .object(["name": .string("Renamed")])]),
            .object(["key": .string("rate"), "patch": .object(["value": .double(7)])]),
        ])

        #expect(result["ok"]?.boolValue == false)
        // The valid first entry must NOT have landed.
        let out = calc(store, miniAppId)?.rows.first { $0.key == "out" }
        #expect(out?.name == "Out")
    }

    // MARK: - Valid patches still work

    @Test("Presentation-only fields still patch on their own")
    func presentationOnly_succeeds() async throws {
        let (store, miniAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMiniAppTools(on: registry, store: store, miniAppId: miniAppId)
        try await seed(registry)

        let result = try await patch(registry, [
            .object(["key": .string("rate"), "patch": .object([
                "name": .string("Expected return"), "unit": .string("%"),
            ])]),
        ])
        #expect(result["ok"]?.boolValue == true)
        #expect(rate(store, miniAppId)?.name == "Expected return")
        #expect(rate(store, miniAppId)?.unit == "%")
    }

    @Test("A full kind block still replaces row behaviour")
    func fullKindBlock_succeeds() async throws {
        let (store, miniAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMiniAppTools(on: registry, store: store, miniAppId: miniAppId)
        try await seed(registry)

        let result = try await patch(registry, [
            .object(["key": .string("rate"), "patch": .object([
                "kind": .string("variable"),
                "value": .double(7),
                "control": .object([
                    "type": .string("slider"),
                    "min": .double(2), "max": .double(15), "step": .double(0.5),
                ]),
            ])]),
        ])
        #expect(result["ok"]?.boolValue == true)
        #expect(result["patched"]?.arrayValue?.first?.stringValue == "rate")
        guard case .variable(let value, let control)? = rate(store, miniAppId)?.kind else {
            Issue.record("rate is no longer a variable"); return
        }
        #expect(value == 7)
        guard case .slider = control else {
            Issue.record("expected slider, got \(control)"); return
        }
    }
}
