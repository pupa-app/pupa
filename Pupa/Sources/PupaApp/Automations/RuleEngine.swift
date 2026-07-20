import Foundation
import Observation

/// Matches `CanvasEvent`s against loaded `AutomationRule`s and, subject to the
/// v1 guards, surfaces a confirm-bubble proposal (or auto-fires it).
///
/// Guards (issue #209):
/// 1. **In-flight lock** (required) — a `(ruleId, itemId)` key; a matching
///    event whose key is already in flight is dropped. Cleared on dismiss,
///    on `complete`, or by a timeout backstop so a hung reaction can't wedge
///    the rule.
/// 2. **Once-per-transition dedupe** — the same `transitionId` inside a short
///    window fires once; a genuine later re-entry past the window fires again.
/// 3. **Self-mutation** — reaction mutations carry `actor == .agent`, which
///    never emits a `CanvasEvent` (gated in `MyAppStore`), so a reaction can
///    never re-trigger its own rule. No dedicated `.automation` tag in v1.
@MainActor
@Observable
public final class RuleEngine {
    /// A matched rule + the event and rendered prompt it produced.
    public struct Proposal: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let ruleId: String
        public let event: CanvasEvent
        public let prompt: String
        public init(ruleId: String, event: CanvasEvent, prompt: String) {
            self.id = UUID()
            self.ruleId = ruleId
            self.event = event
            self.prompt = prompt
        }
        /// Confirm-bubble body: "Start review chat for *Ship v2*?".
        public var summary: String {
            "Start a chat for \u{201C}\(event.itemTitle)\u{201D}?"
        }
    }

    /// A `confirm: true` proposal awaiting the user's Start / Dismiss. Drives
    /// the bubble in `AppView`.
    public private(set) var pendingProposal: Proposal?
    /// A `confirm: false` proposal to auto-fire (no bubble). `AppView` observes
    /// it, runs the reaction, and clears it via `consumeAutoFire`.
    public private(set) var pendingAutoFire: Proposal?

    private var inFlight: Set<String> = []
    private var recentTransitions: [String: Date] = [:]
    private let dedupeWindow: TimeInterval
    private let lockTimeout: TimeInterval
    private let now: () -> Date

    public init(
        dedupeWindow: TimeInterval = 1.0,
        lockTimeout: TimeInterval = 120,
        now: @escaping () -> Date = Date.init
    ) {
        self.dedupeWindow = dedupeWindow
        self.lockTimeout = lockTimeout
        self.now = now
    }

    private func lockKey(_ ruleId: String, _ itemId: UUID) -> String {
        "\(ruleId)|\(itemId.uuidString)"
    }

    /// Ingest one event, matching it against `rules`. Rules are passed in
    /// (loaded fresh from the event's MyApp bundle) so the engine stays
    /// decoupled from disk. First matching, unlocked, non-deduped rule per
    /// event is dispatched.
    public func ingest(_ event: CanvasEvent, rules: [AutomationRule]) {
        let fields = event.matchFields
        for rule in rules where rule.event == event.type && Self.matches(rule.matcher, fields) {
            dispatch(rule, event)
        }
    }

    /// Generic equality predicate: every `matcher` key must equal the event's
    /// `matchFields` value (AND). Empty matcher ⇒ matches any.
    private static func matches(_ matcher: [String: String], _ fields: [String: String]) -> Bool {
        for (key, expected) in matcher where fields[key] != expected { return false }
        return true
    }

    private func dispatch(_ rule: AutomationRule, _ event: CanvasEvent) {
        // Guard 2: once-per-transition dedupe.
        let t = now()
        if let last = recentTransitions[event.transitionId], t.timeIntervalSince(last) < dedupeWindow {
            NSLog("[RuleEngine] deduped transition \(event.transitionId) for rule \(rule.id)")
            return
        }
        // Evict entries past the window so the map can't grow unbounded over a
        // long session — a stale entry can never dedupe anything again.
        recentTransitions = recentTransitions.filter { t.timeIntervalSince($0.value) < dedupeWindow }
        recentTransitions[event.transitionId] = t

        // Guard 1: in-flight lock.
        let key = lockKey(rule.id, event.itemId)
        guard !inFlight.contains(key) else {
            NSLog("[RuleEngine] dropped \(rule.id): reaction already in flight for item")
            return
        }
        inFlight.insert(key)

        let prompt: String
        if let template = rule.action.startThreadPrompt {
            prompt = AutomationRule.render(template, event: event)
        } else {
            prompt = ""
        }
        let proposal = Proposal(ruleId: rule.id, event: event, prompt: prompt)
        if rule.confirm {
            pendingProposal = proposal
        } else {
            pendingAutoFire = proposal
        }
        armTimeout(key)
    }

    /// User tapped Start: clear the bubble, keep the lock until the reaction
    /// terminates (or times out).
    public func accept(_ proposal: Proposal) {
        if pendingProposal?.id == proposal.id { pendingProposal = nil }
    }

    /// User tapped Dismiss: clear the bubble and release the lock.
    public func dismiss(_ proposal: Proposal) {
        if pendingProposal?.id == proposal.id { pendingProposal = nil }
        release(proposal.ruleId, proposal.event.itemId)
    }

    /// `AppView` consumed an auto-fire proposal; clear the slot (lock stays
    /// until termination / timeout).
    public func consumeAutoFire(_ proposal: Proposal) {
        if pendingAutoFire?.id == proposal.id { pendingAutoFire = nil }
    }

    /// Reaction terminated (thread done / failed / dismissed) — release the
    /// rule's lock so the same item can react again.
    public func complete(ruleId: String, itemId: UUID) {
        release(ruleId, itemId)
    }

    private func release(_ ruleId: String, _ itemId: UUID) {
        inFlight.remove(lockKey(ruleId, itemId))
    }

    /// Backstop: a reaction that never signals completion must not wedge the
    /// rule forever. Clear the lock after `lockTimeout` and warn.
    private func armTimeout(_ key: String) {
        let timeout = lockTimeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.inFlight.contains(key) else { return }
            self.inFlight.remove(key)
            NSLog("[RuleEngine] lock \(key) timed out after \(timeout)s — cleared")
        }
    }
}
