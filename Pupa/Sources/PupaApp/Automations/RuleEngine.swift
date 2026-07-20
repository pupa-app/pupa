import Foundation

/// A matched rule ready for dispatch. Pure data — no UI coupling.
public struct AutomationProposal: Sendable, Equatable {
    public let ruleId: String
    public let myAppId: UUID
    public let itemId: UUID
    public let transitionId: String
    /// `startThread` prompt with `{{item.title}}` already rendered.
    public let prompt: String
    /// `confirm: false` → skip the bubble and fire immediately.
    public let autoSend: Bool
}

/// Pure matcher + guard core. No UI, no store, no I/O — the live-or-die
/// surface, unit-tested in isolation.
///
/// Guards enforced here (issue #209):
/// 1. In-flight lock, keyed `(ruleId, itemId)` — a rule never re-fires while
///    its own reaction is live. Cleared via `clearLock` on termination.
/// 2. Once-per-transition dedupe on `transitionId` — fire on *entering* a
///    state, not on every re-persist. A later re-entry is a fresh transition.
/// 3. Reentrancy — an event tagged `automationOrigin` never matches.
@MainActor
public final class RuleEngine {
    private struct LockKey: Hashable { let ruleId: String; let itemId: UUID }

    /// Transitions already fired, keyed `ruleId|transitionId` (dedupe).
    private var firedTransitions: Set<String> = []
    /// Rules with a live reaction (in-flight lock).
    private var inFlight: Set<LockKey> = []

    public init() {}

    /// Match `event` against `rules`, applying all three guards. Returns the
    /// proposals to dispatch (empty if none). Firing a proposal atomically
    /// records its dedupe key and takes its in-flight lock.
    public func evaluate(event: CanvasEvent, rules: [AutomationRule]) -> [AutomationProposal] {
        // Guard 3: a reaction's own mutations never re-trigger a rule.
        guard !event.automationOrigin else { return [] }

        var proposals: [AutomationProposal] = []
        for rule in rules where rule.event == event.type {
            guard matches(rule.matcher, event.matchFields) else { continue }

            let dedupeKey = "\(rule.id)|\(event.transitionId)"
            guard !firedTransitions.contains(dedupeKey) else { continue }   // Guard 2

            let lock = LockKey(ruleId: rule.id, itemId: event.itemId)
            guard !inFlight.contains(lock) else { continue }                // Guard 1

            firedTransitions.insert(dedupeKey)
            inFlight.insert(lock)
            proposals.append(AutomationProposal(
                ruleId: rule.id,
                myAppId: event.myAppId,
                itemId: event.itemId,
                transitionId: event.transitionId,
                prompt: render(rule.action.startThreadPrompt ?? "", title: event.itemTitle),
                autoSend: !rule.confirm
            ))
        }
        return proposals
    }

    /// Release a rule's in-flight lock so it may fire again for its item.
    /// Called when a reaction terminates (thread closed / dismissed / failed
    /// / timed out).
    public func clearLock(ruleId: String, itemId: UUID) {
        inFlight.remove(LockKey(ruleId: ruleId, itemId: itemId))
    }

    private func matches(_ matcher: [String: String], _ fields: [String: String]) -> Bool {
        for (key, expected) in matcher where fields[key] != expected { return false }
        return true
    }

    private func render(_ template: String, title: String?) -> String {
        template.replacingOccurrences(of: "{{item.title}}", with: title ?? "")
    }
}
