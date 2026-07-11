import SwiftUI
import AGUIKit

/// The calendar kind's `ComponentModule` (issue #162). Mirrors `TrackerModule`:
/// one folder, one self-registering module, own single-case unwrap on
/// `CanvasApp` instead of the central exhaustive switch.
@MainActor
public struct CalendarModule: ComponentModule {
    public init() {}

    public let kind = "calendar"
    public let defaultIcon = "calendar"

    /// Sourced from the `MyAppType.tracker.kinds` literal until the full #162
    /// pass inverts it (assembly-from-registry). Zero drift meanwhile.
    public var kindSpec: ComponentKindSpec {
        MyAppType.tracker.kinds["calendar"]
            ?? ComponentKindSpec(tools: [], catalogBlurb: "calendar")
    }

    public var itemPolicy: (any AnyItemPolicy)? { CalendarEventPolicy() }
    public var exportPolicy: any ComponentExportPolicy { CalendarExportPolicy() }

    public func makeEmptyBody() -> CanvasApp {
        .calendar(CalendarData(title: "", events: []))
    }

    public func itemCount(_ body: CanvasApp) -> Int {
        guard case .calendar(let c) = body else { return 0 }
        return c.events.count
    }

    public func emptyHint() -> (headline: String, subline: String) {
        (
            "This calendar is empty",
            "Tell the chat what events to add. Try \"Add a dentist appointment Tuesday at 10am\"."
        )
    }

    public func makeView(
        component: Component,
        store: MyAppStore,
        myAppId: UUID,
        coordinator: ChatSessionCoordinator?
    ) -> AnyView {
        guard case .calendar(let data) = component.body else { return AnyView(EmptyView()) }
        return AnyView(CalendarView(
            store: store, data: data, myAppId: myAppId, componentId: component.id))
    }

    public func registerTools(on registry: ToolRegistry, context: ComponentToolContext) {
        AppTools.registerCalendarTools(
            on: registry, store: context.store, myAppId: context.myAppId)
    }
}
