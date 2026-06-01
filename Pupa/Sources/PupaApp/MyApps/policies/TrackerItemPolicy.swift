import Foundation

/// Per-kind guardrails for `TrackerItem`. Registered in `ItemPolicyRegistry`
/// at app bootstrap so `MyAppStore.linkItems` and cascade routing can consult
/// it uniformly once Phases 3–4 complete the full migration.
public struct TrackerItemPolicy: ItemPolicy {
    public typealias ItemType = TrackerItem

    public var maxLinkedItems: Int { 50 }
    public var maxDisplayNameLength: Int { 500 }

    /// Tracker items may link to tracker, calendar, and checklist components.
    /// Slack and empty are excluded — slack has no stable item ids, and empty
    /// components have no items to link to.
    public func canLinkTo(targetKind: String) -> Bool {
        ["tracker", "calendar", "checklist"].contains(targetKind)
    }

    /// No structural invariants on a tracker item's `values` dict — every
    /// field is optional, and the field schema lives on `TrackerData`, not
    /// the individual row. Override with `validate` when a specific tracker
    /// type adds required-field semantics in the future.
    public func validate(_ item: TrackerItem) -> [ItemValidationError] { [] }
}
