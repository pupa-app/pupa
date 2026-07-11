import SwiftUI
import AGUIKit

/// The chart kind's `ComponentModule` (issue #162). No `itemPolicy` (a chart's
/// series reference other components via specs, handled by the unified ref
/// model on `CanvasApp`, not the universal item graph).
@MainActor
public struct ChartModule: ComponentModule {
    public init() {}

    public let kind = "chart"
    public let defaultIcon = "chart.pie"

    /// Sourced from the `MyAppType.tracker.kinds` literal until the full #162
    /// pass inverts it (assembly-from-registry). Zero drift meanwhile.
    public var kindSpec: ComponentKindSpec {
        MyAppType.tracker.kinds["chart"]
            ?? ComponentKindSpec(tools: [], catalogBlurb: "chart")
    }

    // itemPolicy defaults to nil (protocol extension).
    public var exportPolicy: any ComponentExportPolicy { ChartExportPolicy() }

    public func makeEmptyBody() -> CanvasApp {
        .chart(ChartData(title: ""))
    }

    public func itemCount(_ body: CanvasApp) -> Int {
        guard case .chart(let c) = body else { return 0 }
        return c.inlinePointCount
    }

    public func emptyHint() -> (headline: String, subline: String) {
        (
            "This chart is empty",
            "Tell the chat what to plot. Try \"Pie chart of spend by cuisine\" or \"Bar chart of monthly totals\"."
        )
    }

    public func makeView(
        component: Component,
        store: MyAppStore,
        myAppId: UUID,
        coordinator: ChatSessionCoordinator?
    ) -> AnyView {
        guard case .chart(let data) = component.body else { return AnyView(EmptyView()) }
        return AnyView(ChartContainerView(store: store, data: data, myAppId: myAppId))
    }

    public func registerTools(on registry: ToolRegistry, context: ComponentToolContext) {
        AppTools.registerChartTools(
            on: registry, store: context.store, myAppId: context.myAppId)
    }
}
