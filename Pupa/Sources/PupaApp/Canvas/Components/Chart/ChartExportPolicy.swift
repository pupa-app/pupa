import Foundation

/// Chart: series specs are structure — nothing to strip.
public struct ChartExportPolicy: ComponentExportPolicy {
    public init() {}
    public let kind = "chart"
    public func strippingUserData(_ body: CanvasApp) -> CanvasApp { body }
}
