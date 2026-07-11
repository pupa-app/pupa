import SwiftUI
import AGUIKit

/// The checklist kind's `ComponentModule` (issue #162). Mirrors `TrackerModule`.
@MainActor
public struct ChecklistModule: ComponentModule {
    public init() {}

    public let kind = "checklist"
    public let defaultIcon = "checklist"

    /// Sourced from the `MyAppType.tracker.kinds` literal until the full #162
    /// pass inverts it (assembly-from-registry). Zero drift meanwhile.
    public var kindSpec: ComponentKindSpec {
        MyAppType.tracker.kinds["checklist"]
            ?? ComponentKindSpec(tools: [], catalogBlurb: "checklist")
    }

    public var itemPolicy: (any AnyItemPolicy)? { ChecklistItemPolicy() }
    public var exportPolicy: any ComponentExportPolicy { ChecklistExportPolicy() }

    public func makeEmptyBody() -> CanvasApp {
        .checklist(ChecklistData(title: "", items: []))
    }

    public func itemCount(_ body: CanvasApp) -> Int {
        guard case .checklist(let cl) = body else { return 0 }
        return cl.items.count
    }

    public func emptyHint() -> (headline: String, subline: String) {
        (
            "This checklist is empty",
            "Tell the chat what to list. Try \"Make a packing list for a weekend trip\" or \"Things to do today\"."
        )
    }

    public func makeView(
        component: Component,
        store: MyAppStore,
        myAppId: UUID,
        coordinator: ChatSessionCoordinator?
    ) -> AnyView {
        guard case .checklist(let data) = component.body else { return AnyView(EmptyView()) }
        return AnyView(ChecklistView(
            store: store, data: data, myAppId: myAppId, componentId: component.id))
    }

    public func registerTools(on registry: ToolRegistry, context: ComponentToolContext) {
        AppTools.registerChecklistTools(
            on: registry, store: context.store, myAppId: context.myAppId)
    }
}
