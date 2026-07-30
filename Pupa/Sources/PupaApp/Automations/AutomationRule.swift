import Foundation

/// A canvas **domain** event — the trigger side of an automation. Emitted from
/// `MyAppStore`'s single mutation choke-point, never persisted. These are Pupa
/// domain events (something only Pupa can observe), NOT Claude Code harness
/// hooks. v1 carries only `.itemMoved`.
public struct CanvasEvent: Sendable, Equatable {
    public enum EventType: String, Codable, Sendable {
        case itemMoved = "item.moved"
    }

    public let type: EventType
    public let myAppId: UUID
    public let componentId: String
    public let itemId: UUID
    /// Best-effort display name of the moved item (for `{{item.title}}`).
    public let itemTitle: String
    /// The item's field values after the move (for `{{item.<field>}}` and for
    /// `matchFields` equality predicates on any field).
    public let values: [String: String]
    /// Name of the select field whose value changed. Independent of the
    /// tracker's kanban group-by — a move is a domain fact, not a property of
    /// the view. Scope a rule to one field with `matcher: {"field": "…"}`.
    public let field: String
    public let fromColumn: String?
    public let toColumn: String?

    public init(
        type: EventType,
        myAppId: UUID,
        componentId: String,
        itemId: UUID,
        itemTitle: String,
        values: [String: String] = [:],
        field: String,
        fromColumn: String?,
        toColumn: String?
    ) {
        self.type = type
        self.myAppId = myAppId
        self.componentId = componentId
        self.itemId = itemId
        self.itemTitle = itemTitle
        self.values = values
        self.field = field
        self.fromColumn = fromColumn
        self.toColumn = toColumn
    }

    /// Stable id for `(item, type, field, from→to)` — the once-per-transition
    /// dedupe key. Field-scoped so one patch touching two select fields isn't
    /// deduped down to a single event. A later re-entry into the same state is
    /// the same transitionId and is distinguished only by time (see
    /// `RuleEngine` dedupe window).
    public var transitionId: String {
        "\(itemId.uuidString)|\(type.rawValue)|\(field)|\(fromColumn ?? "")->\(toColumn ?? "")"
    }

    /// Field values a rule `matcher` is tested against (equality predicates,
    /// all AND). The item's own field values plus the structural transition
    /// keys `field` / `toColumn` / `fromColumn`, so a matcher can key off any
    /// event field without a schema change (forward-compatible to
    /// `field.changed`, `item.added`, multi-field AND).
    public var matchFields: [String: String] {
        var f = values
        f["field"] = field
        if let toColumn { f["toColumn"] = toColumn }
        if let fromColumn { f["fromColumn"] = fromColumn }
        return f
    }
}

/// Action side of a rule. v1: `startThread` with a prompt template. Kept a
/// struct (not a bare String) so `runSkill` / `runWorkflow` slot in later
/// without touching call sites.
public struct AutomationAction: Sendable, Equatable {
    /// `startThread` prompt template. Substituted at dispatch (see
    /// `AutomationRule.render`). Non-nil is the only supported v1 shape.
    public var startThreadPrompt: String?

    public init(startThreadPrompt: String? = nil) {
        self.startThreadPrompt = startThreadPrompt
    }
}

/// One declarative automation rule, loaded from a bundle's
/// `pupa/automations.json`. Naming mirrors Claude Code hook config where the
/// concept maps — event-name → `matcher` → `action`.
public struct AutomationRule: Sendable, Equatable, Identifiable {
    public let id: String
    /// Which event name this rule was listed under (the config grouping key).
    public var event: CanvasEvent.EventType
    /// Equality predicates on the event's `matchFields` (all must hold — AND).
    /// Empty ⇒ matches any event of `event`'s type.
    public var matcher: [String: String]
    public var action: AutomationAction
    /// Confirm-bubble gate. Default `true` (propose, don't auto-fire).
    public var confirm: Bool

    public init(
        id: String,
        event: CanvasEvent.EventType,
        matcher: [String: String] = [:],
        action: AutomationAction = .init(),
        confirm: Bool = true
    ) {
        self.id = id
        self.event = event
        self.matcher = matcher
        self.action = action
        self.confirm = confirm
    }

    /// Render an action prompt template against an event. Substitutes
    /// `{{item.title}}`, `{{item.<field>}}`, `{{field}}`, `{{fromColumn}}`,
    /// `{{toColumn}}` with literal field values — no code evaluation.
    public static func render(_ template: String, event: CanvasEvent) -> String {
        var out = template
        out = out.replacingOccurrences(of: "{{item.title}}", with: event.itemTitle)
        out = out.replacingOccurrences(of: "{{field}}", with: event.field)
        out = out.replacingOccurrences(of: "{{fromColumn}}", with: event.fromColumn ?? "")
        out = out.replacingOccurrences(of: "{{toColumn}}", with: event.toColumn ?? "")
        for (k, v) in event.values {
            out = out.replacingOccurrences(of: "{{item.\(k)}}", with: v)
        }
        return out
    }
}

/// Parser for `pupa/automations.json`.
///
/// Shape mirrors Claude Code's `hooks: { <EventName>: [ {matcher, …} ] }`:
/// an `automations` map keyed by the domain event name, each a list of rules.
/// The `automations` top-level wrapper leaves room for future config keys.
///
/// Deliberately **per-entry tolerant** — imported bundles are treated as
/// hostile, so a malformed / missing-id / unknown-verb / unknown-event entry
/// is skipped without failing the rest of the file (same posture as the
/// `.pupa` importer). See docs/marketplace.md.
public enum AutomationConfig {
    /// Parse rule text into a flat, event-tagged rule list. Never throws;
    /// returns `[]` on unreadable input. Rules are sorted by id for a
    /// deterministic order.
    public static func parse(_ json: String) -> [AutomationRule] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let automations = root["automations"] as? [String: Any] else { return [] }

        var rules: [AutomationRule] = []
        for (eventKey, value) in automations {
            guard let event = CanvasEvent.EventType(rawValue: eventKey),   // unknown event → skip
                  let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let rule = parseRule(entry, event: event) else { continue }   // bad entry → skip
                rules.append(rule)
            }
        }
        return rules.sorted { $0.id < $1.id }
    }

    private static func parseRule(_ entry: [String: Any], event: CanvasEvent.EventType) -> AutomationRule? {
        guard let id = (entry["id"] as? String)?.nonEmpty,
              let actionDict = entry["action"] as? [String: Any] else { return nil }

        // v1: only `startThread` with a non-empty prompt. Unknown verbs skip.
        guard let startThread = actionDict["startThread"] as? [String: Any],
              let prompt = (startThread["prompt"] as? String)?.nonEmpty else { return nil }

        let matcher = (entry["matcher"] as? [String: Any])?
            .compactMapValues { $0 as? String } ?? [:]
        let confirm = entry["confirm"] as? Bool ?? true   // default: propose, don't auto-fire

        return AutomationRule(
            id: id,
            event: event,
            matcher: matcher,
            action: AutomationAction(startThreadPrompt: prompt),
            confirm: confirm
        )
    }
}
