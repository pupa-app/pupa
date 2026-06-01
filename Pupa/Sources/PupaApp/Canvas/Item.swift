import Foundation

public struct ItemValidationError: Error, Sendable, Equatable {
    public let field: String
    public let reason: String

    public init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }
}

/// Shared identity + linking contract for all item kinds (tracker rows,
/// calendar events, checklist rows, …). Conforming to this protocol
/// unlocks free `deduplicateLinkedItems()` and a default `validate()`
/// that returns no errors — each kind overrides `validate()` to add its
/// own invariants (non-empty title, parseable ISO-8601 start, etc.).
///
/// `schemaVersion` is written on encode (default: 1) and read by
/// `MigrationRegistry` before normal decoding so old on-disk blobs can
/// be migrated forward without bespoke per-kind `init(from:)` branches.
///
/// `displayName` and `kind` have no defaults — every conforming type
/// must supply them. `displayName` is used by linked-item pills and
/// pickers; `kind` must match the `CanvasApp` discriminator string
/// ("tracker", "calendar", "checklist", …).
public protocol Item: Identifiable, Codable, Hashable, Sendable where ID == UUID {
    var id: UUID { get }
    var linkedItems: [ComponentItemRef] { get set }
    var schemaVersion: Int { get }
    var displayName: String { get }
    static var kind: String { get }
}

public extension Item {
    var schemaVersion: Int { 1 }

    mutating func deduplicateLinkedItems() {
        var seen = Set<ComponentItemRef>()
        linkedItems = linkedItems.filter { seen.insert($0).inserted }
    }

    func validate() -> [ItemValidationError] { [] }
}
