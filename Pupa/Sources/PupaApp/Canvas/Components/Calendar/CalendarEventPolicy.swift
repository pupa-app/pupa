import Foundation

/// Per-kind guardrails for `CalendarEvent`. Registered in `ItemPolicyRegistry`
/// at app bootstrap so `MyAppStore.linkItems` and cascade routing can consult
/// it uniformly once Phase 4 completes the full migration.
public struct CalendarEventPolicy: ItemPolicy {
    public typealias ItemType = CalendarEvent

    public var maxLinkedItems: Int { 50 }
    public var maxDisplayNameLength: Int { 500 }

    /// Calendar events may link to tracker, calendar, and checklist components.
    /// Slack and empty are excluded — slack has no stable item ids, and empty
    /// components have no items to link to.
    public func canLinkTo(targetKind: String) -> Bool {
        ["tracker", "calendar", "checklist"].contains(targetKind)
    }

    /// Validates a calendar event's structural invariants: title must be
    /// non-empty and start must be a parseable ISO-8601 date string.
    public func validate(_ item: CalendarEvent) -> [ItemValidationError] {
        var errors: [ItemValidationError] = []
        if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(ItemValidationError(field: "title", reason: "must not be empty"))
        }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmt2 = ISO8601DateFormatter()
        if fmt.date(from: item.start) == nil && fmt2.date(from: item.start) == nil {
            errors.append(ItemValidationError(field: "start", reason: "must be a valid ISO-8601 date string"))
        }
        return errors
    }
}
