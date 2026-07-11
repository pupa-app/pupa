import SwiftUI
import AGUIKit

/// The calculator kind's `ComponentModule` (issue #162). No `itemPolicy`
/// (calculator rows aren't universal link targets — cross-component refs are
/// handled by the unified ref model on `CanvasApp`).
@MainActor
public struct CalculatorModule: ComponentModule {
    public init() {}

    public let kind = "calculator"
    public let defaultIcon = "function"

    /// Owned here; `MyAppType.tracker.kinds` assembles from this at load.
    public nonisolated static let kindSpec = ComponentKindSpec(
        tools: [
            "renderCalculator",
            "addCalcRows",
            "patchCalcRows",
            "removeCalcRows",
            "setCalcRowLink",
            "listCalcRows",
            "getCalcRow",
            "embedComponent",
        ],
        promptFragment: """
        CALCULATOR — live numeric model. Rows: tunable inputs (VARIABLE), \
        formulas over other rows by key (FORMULA), tracker aggregates \
        (AGGREGATE), one field off a linked tracker item (LINKED_FIELD — \
        swap the item with setCalcRowLink to re-run the model), array \
        output for charts (LIST, incl. linkedCompare to compare a set of \
        linked items on a target row), section labels (HEADER). Use when \
        user wants a model to tune in real time. Explore via \
        list/getCalcRow; `summary` slot — set via renderCalculator(summary:).
        """,
        catalogBlurb: "live numeric model with tunable inputs + formula rows"
    )
    public var kindSpec: ComponentKindSpec { Self.kindSpec }

    // itemPolicy defaults to nil (protocol extension).
    public var exportPolicy: any ComponentExportPolicy { CalculatorExportPolicy() }

    public func makeEmptyBody() -> CanvasApp {
        .calculator(CalculatorData(title: "", rows: []))
    }

    public func itemCount(_ body: CanvasApp) -> Int {
        guard case .calculator(let c) = body else { return 0 }
        return c.rows.count
    }

    public func emptyHint() -> (headline: String, subline: String) {
        (
            "This calculator is empty",
            "Tell the chat what to compute. Try \"Estimate my monthly mortgage payment\" or \"Total my expenses by category\"."
        )
    }

    public func makeView(
        component: Component,
        store: MyAppStore,
        myAppId: UUID,
        coordinator: ChatSessionCoordinator?
    ) -> AnyView {
        guard case .calculator(let data) = component.body else { return AnyView(EmptyView()) }
        return AnyView(CalculatorView(
            store: store, data: data, myAppId: myAppId, componentId: component.id))
    }

    public func registerTools(on registry: ToolRegistry, context: ComponentToolContext) {
        AppTools.registerCalculatorTools(
            on: registry, store: context.store, myAppId: context.myAppId)
    }
}
