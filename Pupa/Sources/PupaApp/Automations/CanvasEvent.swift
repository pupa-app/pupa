import Foundation

/// A domain event Pupa can observe on the canvas — something the headless
/// model cannot see. Emitted from the single `MyAppStore` mutation
/// choke-point to drive the automation rule engine.
///
/// Distinct from `ItemEvent`: that is the *persisted* History change-feed;
/// `CanvasEvent` is a *transient* reactive signal, never stored. Both are
/// emitted from the same funnel so they cannot drift.
public enum CanvasEventType: String, Codable, Sendable {
    /// A tracker card crossed kanban columns (its `columnField` value
    /// changed). The only v1 event.
    case itemMoved = "item.moved"
}

/// One transient canvas signal. Field payload for matcher evaluation lives
/// in `matchFields`; only the fields relevant to `type` are populated.
public struct CanvasEvent: Sendable, Equatable {
    public let type: CanvasEventType
    public let myAppId: UUID
    public let componentId: String
    public let itemId: UUID
    /// Component/shape kind, e.g. `"tracker"`.
    public let kind: String
    /// `item.moved`: prior / next value of the kanban `columnField`.
    public let fromColumn: String?
    public let toColumn: String?
    /// Best-effort item display title, for `{{item.title}}` templating.
    public let itemTitle: String?
    /// Stable id for (item, field, from→to) — the once-per-transition
    /// dedupe key. Re-entering a state later is a fresh transition.
    public let transitionId: String
    /// Thread that caused the mutation, if any. Lets a reaction's own
    /// mutations be recognised and skipped (reentrancy guard).
    public let originThreadId: String?
    /// True when this mutation was performed by an automation reaction.
    /// Set false at the choke-point; the coordinator re-stamps it from its
    /// spawned-thread set before matching.
    public var automationOrigin: Bool

    public init(
        type: CanvasEventType,
        myAppId: UUID,
        componentId: String,
        itemId: UUID,
        kind: String,
        fromColumn: String? = nil,
        toColumn: String? = nil,
        itemTitle: String? = nil,
        transitionId: String,
        originThreadId: String? = nil,
        automationOrigin: Bool = false
    ) {
        self.type = type
        self.myAppId = myAppId
        self.componentId = componentId
        self.itemId = itemId
        self.kind = kind
        self.fromColumn = fromColumn
        self.toColumn = toColumn
        self.itemTitle = itemTitle
        self.transitionId = transitionId
        self.originThreadId = originThreadId
        self.automationOrigin = automationOrigin
    }

    /// Field values a rule `matcher` is tested against (equality predicates).
    public var matchFields: [String: String] {
        var f: [String: String] = ["kind": kind]
        if let toColumn { f["toColumn"] = toColumn }
        if let fromColumn { f["fromColumn"] = fromColumn }
        return f
    }

    /// Build the stable dedupe id for a column transition.
    public static func transitionId(itemId: UUID, field: String, from: String?, to: String?) -> String {
        "\(itemId.uuidString)|\(field)|\(from ?? "")|\(to ?? "")"
    }
}
