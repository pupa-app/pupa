import SwiftUI
import AGUIKit

/// The checklist kind's `ComponentModule` (issue #162). Mirrors `TrackerModule`.
@MainActor
public struct ChecklistModule: ComponentModule {
    public init() {}

    public let kind = "checklist"
    public let defaultIcon = "checklist"

    /// Owned here; `MyAppType.tracker.kinds` assembles from this at load.
    public nonisolated static let kindSpec = ComponentKindSpec(
        tools: [
            "renderChecklist",
            "addChecklistItem",
            "toggleChecklistItem",
            "patchChecklistItem",
            "removeChecklistItem",
            "listChecklistItems",
            "getChecklistItem",
        ],
        promptFragment: """
        CHECKLIST — done/not-done rows, no per-row metadata. Switch to \
        TRACKER once rows need multiple fields. Explore via \
        list/getChecklistItem; `summary` slot — set via renderChecklist(summary:).
        """,
        catalogBlurb: "simple done/not-done items, no per-row fields"
    )
    public var kindSpec: ComponentKindSpec { Self.kindSpec }

    public var itemPolicy: (any AnyItemPolicy)? { ChecklistItemPolicy() }
    public var exportPolicy: any ComponentExportPolicy { ChecklistExportPolicy() }

    public var isLinkable: Bool { true }
    public var linkPickerEmptyHint: String { "No rows on this checklist yet" }
    public func linkableItems(
        in component: Component,
        store: MyAppStore,
        myAppId: UUID
    ) -> [(id: UUID, displayName: String)] {
        guard case .checklist(let cl) = component.body else { return [] }
        return cl.items.map { item in
            (item.id, item.text.isEmpty ? "(empty item)" : item.text)
        }
    }

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
