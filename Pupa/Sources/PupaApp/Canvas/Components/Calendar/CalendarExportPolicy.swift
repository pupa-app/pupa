import Foundation

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
