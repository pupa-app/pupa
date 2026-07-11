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

/// Slack: keep channels (the reusable workspace); drop the chat transcript.
/// Agent personas travel separately as `pupa/agents/<slug>/AGENTS.md` files in
/// the app memory tree — they are not part of `SlackData`.
public struct SlackExportPolicy: ComponentExportPolicy {
    public init() {}
    public let kind = "slack"
    public func strippingUserData(_ body: CanvasApp) -> CanvasApp {
        guard case .slack(var s) = body else { return body }
        s.messagesByChannel = [:]
        s.activeChannelId = nil
        return .slack(s)
    }
    public var exportDataWarning: String? {
        "Slack keeps channels; agent personas travel as pupa/agents/ files. Chat messages are removed when records are excluded."
    }
}

/// Chart: series specs are structure — nothing to strip.
public struct ChartExportPolicy: ComponentExportPolicy {
    public init() {}
    public let kind = "chart"
    public func strippingUserData(_ body: CanvasApp) -> CanvasApp { body }
}
