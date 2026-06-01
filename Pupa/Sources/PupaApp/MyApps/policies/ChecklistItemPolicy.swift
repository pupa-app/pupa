import Foundation

/// Per-kind guardrails for `ChecklistItem`. Registered in `ItemPolicyRegistry`
/// at app bootstrap so `MyAppStore.linkItems` and cascade routing can consult
/// it uniformly now that Phase 4 completes the full migration.
public struct ChecklistItemPolicy: ItemPolicy {
    public typealias ItemType = ChecklistItem

    public var maxLinkedItems: Int { 50 }
    public var maxDisplayNameLength: Int { 500 }

    /// Checklist items may link to tracker, calendar, and checklist components.
    /// Slack and empty are excluded — slack has no stable item ids, and empty
    /// components have no items to link to.
    public func canLinkTo(targetKind: String) -> Bool {
        ["tracker", "calendar", "checklist"].contains(targetKind)
    }

    /// Validates a checklist item's structural invariants: text must be
    /// non-empty.
    public func validate(_ item: ChecklistItem) -> [ItemValidationError] {
        var errors: [ItemValidationError] = []
        if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(ItemValidationError(field: "text", reason: "must not be empty"))
        }
        return errors
    }
}
