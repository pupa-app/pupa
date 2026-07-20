import Foundation
import Testing
@testable import PupaApp

/// The live-or-die surface: pure matching + the three required guards
/// (in-flight lock, once-per-transition dedupe, self-mutation reentrancy).
@MainActor
@Suite("Automation rule engine")
struct AutomationRuleEngineTests {

    private let app = UUID()
    private let comp = "c1"

    private func rule(id: String = "review-on-move",
                      matcher: [String: String] = ["toColumn": "Review"],
                      confirm: Bool = true) -> AutomationRule {
        AutomationRule(id: id, event: .itemMoved, matcher: matcher,
                       action: AutomationAction(startThreadPrompt: "Review {{item.title}}."),
                       confirm: confirm)
    }

    private func moved(item: UUID, from: String?, to: String?, title: String = "Ship v2",
                       origin: Bool = false) -> CanvasEvent {
        CanvasEvent(type: .itemMoved, myAppId: app, componentId: comp, itemId: item,
                    kind: "tracker", fromColumn: from, toColumn: to, itemTitle: title,
                    transitionId: CanvasEvent.transitionId(itemId: item, field: "Status", from: from, to: to),
                    automationOrigin: origin)
    }

    @Test("equality matcher: matches the target column, ignores others")
    func equalityMatching() {
        let engine = RuleEngine()
        let item = UUID()
        #expect(engine.evaluate(event: moved(item: item, from: "Doing", to: "Review"),
                                rules: [rule()]).count == 1)

        let engine2 = RuleEngine()
        #expect(engine2.evaluate(event: moved(item: UUID(), from: "Todo", to: "Doing"),
                                 rules: [rule()]).isEmpty)
    }

    @Test("template renders {{item.title}} from the event")
    func templateRender() {
        let engine = RuleEngine()
        let p = engine.evaluate(event: moved(item: UUID(), from: "Doing", to: "Review", title: "Ship v2"),
                                rules: [rule()])
        #expect(p.first?.prompt == "Review Ship v2.")
    }

    @Test("once-per-transition dedupe: same transition fires once; a fresh one fires again")
    func dedupe() {
        let engine = RuleEngine()
        let item = UUID()
        let ev = moved(item: item, from: "Doing", to: "Review")
        #expect(engine.evaluate(event: ev, rules: [rule()]).count == 1)   // first entry fires
        #expect(engine.evaluate(event: ev, rules: [rule()]).isEmpty)      // same transition — deduped

        // Re-entering Review via a different prior column is a new transition
        // (distinct transitionId) → fires again.
        engine.clearLock(ruleId: "review-on-move", itemId: item)          // reaction done
        let fresh = moved(item: item, from: "Blocked", to: "Review")
        #expect(engine.evaluate(event: fresh, rules: [rule()]).count == 1)
    }

    @Test("in-flight lock: re-match dropped while live; fires again after clearLock; unrelated rule still fires")
    func inFlightLock() {
        let engine = RuleEngine()
        let item = UUID()

        // Transition A fires and takes the (rule, item) lock.
        #expect(engine.evaluate(event: moved(item: item, from: "Doing", to: "Review"),
                                rules: [rule()]).count == 1)

        // Transition B (fresh id) while the lock is held → dropped by the lock,
        // not by dedupe.
        let locked = engine.evaluate(event: moved(item: item, from: "Blocked", to: "Review"),
                                     rules: [rule()])
        #expect(locked.isEmpty)

        // An unrelated rule is not blocked by the first rule's lock.
        let other = rule(id: "other-rule")
        #expect(engine.evaluate(event: moved(item: item, from: "Parked", to: "Review"),
                                rules: [other]).count == 1)

        // After the reaction terminates, a new transition fires again.
        engine.clearLock(ruleId: "review-on-move", itemId: item)
        #expect(engine.evaluate(event: moved(item: item, from: "Waiting", to: "Review"),
                                rules: [rule()]).count == 1)
    }

    @Test("reentrancy: an automation-origin event never matches")
    func reentrancyGuard() {
        let engine = RuleEngine()
        #expect(engine.evaluate(event: moved(item: UUID(), from: "Doing", to: "Review", origin: true),
                                rules: [rule()]).isEmpty)
    }

    @Test("confirm default on → propose (autoSend false); confirm:false → auto-fire")
    func confirmToggle() {
        let onEngine = RuleEngine()
        let on = onEngine.evaluate(event: moved(item: UUID(), from: "Doing", to: "Review"),
                                   rules: [rule(confirm: true)])
        #expect(on.first?.autoSend == false)

        let offEngine = RuleEngine()
        let off = offEngine.evaluate(event: moved(item: UUID(), from: "Doing", to: "Review"),
                                     rules: [rule(confirm: false)])
        #expect(off.first?.autoSend == true)
    }
}
