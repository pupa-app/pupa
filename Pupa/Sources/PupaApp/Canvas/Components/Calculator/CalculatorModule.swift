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

    /// Sourced from the `MyAppType.tracker.kinds` literal until the full #162
    /// pass inverts it (assembly-from-registry). Zero drift meanwhile.
    public var kindSpec: ComponentKindSpec {
        MyAppType.tracker.kinds["calculator"]
            ?? ComponentKindSpec(tools: [], catalogBlurb: "calculator")
    }

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
