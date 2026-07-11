import Foundation

/// Calculator: formulas, variables and specs are all structure — nothing to
/// strip. (Cross-component refs are pruned separately via `remapReferences`.)
public struct CalculatorExportPolicy: ComponentExportPolicy {
    public init() {}
    public let kind = "calculator"
    public func strippingUserData(_ body: CanvasApp) -> CanvasApp { body }
}
