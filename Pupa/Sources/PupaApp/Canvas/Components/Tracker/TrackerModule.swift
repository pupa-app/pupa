import SwiftUI
import AGUIKit

/// The tracker kind's `ComponentModule` — the single registration point for
/// tracker. Reference implementation for issue #162: a contributor mirrors this
/// per new shape (own folder + one module + one register line in
/// `MyAppTypeRegistry.registerBuiltins`).
///
/// Each accessor does its own single-case unwrap on `CanvasApp` instead of the
/// central exhaustive switch, so this module owns only the `.tracker` arm.
@MainActor
public struct TrackerModule: ComponentModule {
    public init() {}

    public let kind = "tracker"
    public let defaultIcon = "list.bullet.rectangle"

    /// Sourced from the `MyAppType.tracker.kinds` literal for now — the single
    /// source of truth stays there until the full #162 pass inverts it
    /// (`MyAppType` assembling its `kinds` map from each module's `kindSpec`,
    /// killing the literal). Reading it here keeps zero drift meanwhile.
    public var kindSpec: ComponentKindSpec {
        MyAppType.tracker.kinds["tracker"]
            ?? ComponentKindSpec(tools: [], catalogBlurb: "tracker")
    }

    public var itemPolicy: (any AnyItemPolicy)? { TrackerItemPolicy() }
    public var exportPolicy: any ComponentExportPolicy { TrackerExportPolicy() }

    public func makeEmptyBody() -> CanvasApp {
        .tracker(TrackerData(title: "", fields: []))
    }

    public func itemCount(_ body: CanvasApp) -> Int {
        guard case .tracker(let t) = body else { return 0 }
        return t.items.count
    }

    public func emptyHint() -> (headline: String, subline: String) {
        (
            "This tracker is empty",
            "Tell the chat what to track. Try \"Build me a wardrobe tracker\" "
                + "or \"I want to log books I've read\"."
        )
    }

    public func makeView(
        component: Component,
        store: MyAppStore,
        myAppId: UUID,
        coordinator: ChatSessionCoordinator?
    ) -> AnyView {
        guard case .tracker(let data) = component.body else { return AnyView(EmptyView()) }
        switch data.viewMode {
        case .grid:
            return AnyView(TrackerView(
                store: store, data: data, myAppId: myAppId, componentId: component.id))
        case .kanban:
            return AnyView(KanbanView(
                store: store, data: data, myAppId: myAppId, componentId: component.id))
        }
    }

    public func registerTools(on registry: ToolRegistry, context: ComponentToolContext) {
        AppTools.registerTrackerTools(
            on: registry, store: context.store, myAppId: context.myAppId)
        AppTools.registerTrackerDiscoveryTools(
            on: registry, store: context.store, myAppId: context.myAppId)
    }
}
