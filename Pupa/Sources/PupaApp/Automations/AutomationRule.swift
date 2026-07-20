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
    /// The item's field values after the move (for `{{item.<field>}}`).
    public let values: [String: String]
    public let fromColumn: String?
    public let toColumn: String?

    public init(
        type: EventType,
        myAppId: UUID,
        componentId: String,
        itemId: UUID,
        itemTitle: String,
        values: [String: String] = [:],
        fromColumn: String?,
        toColumn: String?
    ) {
        self.type = type
        self.myAppId = myAppId
        self.componentId = componentId
        self.itemId = itemId
        self.itemTitle = itemTitle
        self.values = values
        self.fromColumn = fromColumn
        self.toColumn = toColumn
    }

    /// Stable id for `(item, type, from→to)` — the once-per-transition dedupe
    /// key. A later re-entry into the same state is the same transitionId and
    /// is distinguished only by time (see `RuleEngine` dedupe window).
    public var transitionId: String {
        "\(itemId.uuidString)|\(type.rawValue)|\(fromColumn ?? "")->\(toColumn ?? "")"
    }
}

/// Predicate side of a rule — Claude Code's `matcher` term. v1: equality on
/// `toColumn` only. Absent field ⇒ matches any.
public struct AutomationMatcher: Codable, Sendable, Equatable {
    public var toColumn: String?

    public init(toColumn: String? = nil) { self.toColumn = toColumn }

    public func matches(_ event: CanvasEvent) -> Bool {
        if let toColumn, event.toColumn != toColumn { return false }
        return true
    }
}

/// Action side of a rule. v1: `startThread` with a prompt template. Later:
/// `runSkill`, `runWorkflow`, `notify`.
public struct AutomationAction: Codable, Sendable, Equatable {
    public struct StartThread: Codable, Sendable, Equatable {
        public var prompt: String
        public init(prompt: String) { self.prompt = prompt }
    }
    public var startThread: StartThread?

    public init(startThread: StartThread? = nil) { self.startThread = startThread }
}

/// One declarative automation rule. Keyed under an event name in
/// `pupa/automations.json`; `event` is populated from that key on decode.
///
/// Naming mirrors Claude Code hook config where the concept maps —
/// event-name → `matcher` → `action` — rather than the issue's YAML sketch
/// (`on`/`when`/`do`); see the PR body for the per-field justification. The
/// config is JSON because `MemoryStore.writableExtensions` is `{md, json}` and
/// the rest of the `pupa/` config is JSON-shaped.
public struct AutomationRule: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// Which event name this rule was listed under. Not in the per-rule JSON;
    /// set from the top-level key during `decodeSet`.
    public var event: CanvasEvent.EventType
    public var matcher: AutomationMatcher
    public var action: AutomationAction
    /// Confirm-bubble gate. Default `true` (propose, don't auto-fire).
    public var confirm: Bool

    public init(
        id: String,
        event: CanvasEvent.EventType,
        matcher: AutomationMatcher = .init(),
        action: AutomationAction = .init(),
        confirm: Bool = true
    ) {
        self.id = id
        self.event = event
        self.matcher = matcher
        self.action = action
        self.confirm = confirm
    }

    enum CodingKeys: String, CodingKey { case id, matcher, action, confirm }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.matcher = try c.decodeIfPresent(AutomationMatcher.self, forKey: .matcher) ?? .init()
        self.action = try c.decodeIfPresent(AutomationAction.self, forKey: .action) ?? .init()
        self.confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? true
        // Placeholder; overwritten by `decodeSet` from the enclosing key.
        self.event = .itemMoved
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(matcher, forKey: .matcher)
        try c.encode(action, forKey: .action)
        try c.encode(confirm, forKey: .confirm)
    }

    /// Decode the `pupa/automations.json` shape — a dict keyed by event name,
    /// each value an array of rules — into a flat, event-tagged rule list.
    /// Unknown event names are skipped (forward-compatible). Malformed JSON
    /// yields an empty list rather than throwing (inert config).
    public static func decodeSet(_ json: String) -> [AutomationRule] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: [AutomationRule]].self, from: data)
        else { return [] }
        var out: [AutomationRule] = []
        for (key, rules) in raw {
            guard let type = CanvasEvent.EventType(rawValue: key) else { continue }
            for var rule in rules { rule.event = type; out.append(rule) }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Render an action prompt template against an event. Substitutes
    /// `{{item.title}}`, `{{item.<field>}}`, `{{fromColumn}}`, `{{toColumn}}`
    /// with literal field values — no code evaluation.
    public static func render(_ template: String, event: CanvasEvent) -> String {
        var out = template
        out = out.replacingOccurrences(of: "{{item.title}}", with: event.itemTitle)
        out = out.replacingOccurrences(of: "{{fromColumn}}", with: event.fromColumn ?? "")
        out = out.replacingOccurrences(of: "{{toColumn}}", with: event.toColumn ?? "")
        for (k, v) in event.values {
            out = out.replacingOccurrences(of: "{{item.\(k)}}", with: v)
        }
        return out
    }
}
