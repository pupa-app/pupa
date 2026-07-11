import Foundation

/// Tracker: keep the field schema + view config; drop rows and the active
/// filter (a filter references row values).
public struct TrackerExportPolicy: ComponentExportPolicy {
    public init() {}
    public let kind = "tracker"
    public func strippingUserData(_ body: CanvasApp) -> CanvasApp {
        guard case .tracker(var t) = body else { return body }
        t.items = []
        t.filter = [:]
        return .tracker(t)
    }
}
