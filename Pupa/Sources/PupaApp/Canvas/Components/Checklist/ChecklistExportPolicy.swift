import Foundation

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
