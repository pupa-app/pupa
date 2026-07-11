import Foundation

/// Concrete `ComponentExportPolicy`s, one per built-in kind. Registered in
/// `MyAppTypeRegistry.registerBuiltins()`. "Records" = user-entered rows;
/// "structure" = the reusable schema/formulas/personas a template keeps.

/// Calendar: keep title + view mode; drop events.
public struct CalendarExportPolicy: ComponentExportPolicy {
    public init() {}
    public let kind = "calendar"
    public func strippingUserData(_ body: CanvasApp) -> CanvasApp {
        guard case .calendar(var cal) = body else { return body }
        cal.events = []
        return .calendar(cal)
    }
}

/// Checklist: keep title; drop items.
public struct ChecklistExportPolicy: ComponentExportPolicy {
    public init() {}
    public let kind = "checklist"
    public func strippingUserData(_ body: CanvasApp) -> CanvasApp {
        guard case .checklist(var cl) = body else { return body }
        cl.items = []
        return .checklist(cl)
    }
}

/// Calculator: formulas, variables and specs are all structure — nothing to
/// strip. (Cross-component refs are pruned separately via `remapReferences`.)
public struct CalculatorExportPolicy: ComponentExportPolicy {
    public init() {}
    public let kind = "calculator"
    public func strippingUserData(_ body: CanvasApp) -> CanvasApp { body }
}

/// Chart: series specs are structure — nothing to strip.
public struct ChartExportPolicy: ComponentExportPolicy {
    public init() {}
    public let kind = "chart"
    public func strippingUserData(_ body: CanvasApp) -> CanvasApp { body }
}
