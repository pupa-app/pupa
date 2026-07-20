import Foundation

/// What a matched rule does. v1: the only verb is `startThread` (prompt).
/// Kept as a struct (not a bare String) so `runSkill` / `runWorkflow` slot
/// in later without touching call sites.
public struct AutomationAction: Sendable, Equatable {
    /// `startThread` prompt template. `{{item.title}}` is substituted at
    /// dispatch. Non-nil is the only supported shape in v1.
    public let startThreadPrompt: String?

    public init(startThreadPrompt: String?) {
        self.startThreadPrompt = startThreadPrompt
    }
}

/// One declarative automation, loaded from a bundle's `pupa/automations.json`.
public struct AutomationRule: Sendable, Equatable, Identifiable {
    public let id: String
    /// The domain event this rule reacts to (the config grouping key).
    public let event: CanvasEventType
    /// Equality predicates on event `matchFields` (all must hold — AND).
    public let matcher: [String: String]
    public let action: AutomationAction
    /// Propose via a confirm bubble (default) vs auto-fire.
    public let confirm: Bool

    public init(id: String, event: CanvasEventType, matcher: [String: String], action: AutomationAction, confirm: Bool) {
        self.id = id
        self.event = event
        self.matcher = matcher
        self.action = action
        self.confirm = confirm
    }
}

/// Parser for `pupa/automations.json`.
///
/// Shape mirrors Claude Code's `hooks: { <EventName>: [ {matcher, …} ] }`:
/// an `automations` map keyed by the domain event name, each a list of
/// rules. Deliberately tolerant — imported bundles are treated as hostile,
/// so a malformed or unknown-verb entry is skipped without failing the rest
/// (same posture as the `.pupa` importer). See docs/marketplace.md.
public enum AutomationConfig {
    public static let fileName = "automations.json"

    /// Parse rule text into a flat, event-tagged rule list. Never throws;
    /// returns `[]` on unreadable input. Rules are sorted by id for a
    /// deterministic order.
    public static func parse(_ json: String) -> [AutomationRule] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let automations = root["automations"] as? [String: Any] else { return [] }

        var rules: [AutomationRule] = []
        for (eventKey, value) in automations {
            guard let event = CanvasEventType(rawValue: eventKey),
                  let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let rule = parseRule(entry, event: event) else { continue }
                rules.append(rule)
            }
        }
        return rules.sorted { $0.id < $1.id }
    }

    private static func parseRule(_ entry: [String: Any], event: CanvasEventType) -> AutomationRule? {
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
