import Foundation
import Testing
@testable import PupaApp

/// Covers the v1 automation slice (issue #209): JSON config parse, matcher
/// equality, end-to-end `item.moved` emission from the `MyAppStore`
/// choke-point, the in-flight lock, once-per-transition dedupe, the
/// self-mutation (`actor`) gate, and confirm-bubble vs auto-fire.
@MainActor
@Suite("automation rule engine")
struct AutomationRuleEngineTests {

    // MARK: - Fixtures

    /// A kanban tracker with a `status` select field (Todo/Review/Done) and one
    /// Todo item. Returns the store, myApp id, component id, and item id.
    private func kanbanFixture() -> (store: MyAppStore, myAppId: UUID, compId: String, itemId: UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        let compId = store.addComponent(kind: "tracker", name: "Board", iconSystemName: "square",
                                         myAppId: myApp.id)!
        store.setTracker(
            title: "Board",
            fields: [
                FieldDef(name: "title", type: .text),
                FieldDef(name: "status", type: .select, options: ["Todo", "Review", "Done"]),
            ],
            myAppId: myApp.id,
            componentId: compId
        )
        _ = store.setTrackerViewMode(.kanban, columnField: "status", myAppId: myApp.id, componentId: compId)
        let itemId = store.addItem(["title": "Ship v2", "status": "Todo"],
                                   myAppId: myApp.id, componentId: compId)!
        return (store, myApp.id, compId, itemId)
    }

    private func event(to column: String, from: String? = "Todo", itemId: UUID = UUID(),
                       title: String = "Ship v2", field: String = "status") -> CanvasEvent {
        CanvasEvent(type: .itemMoved, myAppId: UUID(), componentId: "c", itemId: itemId,
                    itemTitle: title, values: ["title": title], field: field,
                    fromColumn: from, toColumn: column)
    }

    private func reviewRule(id: String = "review-on-move", confirm: Bool = true) -> AutomationRule {
        AutomationRule(
            id: id, event: .itemMoved,
            matcher: ["toColumn": "Review"],
            action: AutomationAction(startThreadPrompt: "Review {{item.title}}."),
            confirm: confirm
        )
    }

    // MARK: - 1. Config parse

    @Test("decodes event-keyed JSON schema with confirm default true")
    func configParse() {
        let json = """
        {
          "automations": {
            "item.moved": [
              { "id": "review-on-move",
                "matcher": { "toColumn": "Review" },
                "action": { "startThread": { "prompt": "Review {{item.title}}." } } },
              { "id": "ship-it",
                "matcher": { "toColumn": "Done" },
                "action": { "startThread": { "prompt": "Ship it." } },
                "confirm": false }
            ]
          }
        }
        """
        let rules = AutomationConfig.parse(json)
        #expect(rules.count == 2)
        let review = rules.first { $0.id == "review-on-move" }
        #expect(review?.event == .itemMoved)
        #expect(review?.matcher["toColumn"] == "Review")
        #expect(review?.action.startThreadPrompt == "Review {{item.title}}.")
        #expect(review?.confirm == true)   // default when omitted
        #expect(rules.first { $0.id == "ship-it" }?.confirm == false)
    }

    // MARK: - 2. Matcher predicate

    @Test("matcher equality on toColumn: fires on match, not on mismatch")
    func matcherEquality() {
        let engine = RuleEngine()
        engine.ingest(event(to: "Review"), rules: [reviewRule()])
        #expect(engine.pendingProposal != nil)

        let miss = RuleEngine()
        miss.ingest(event(to: "Done"), rules: [reviewRule()])
        #expect(miss.pendingProposal == nil)
    }

    @Test("matcher can scope to one field via the `field` key")
    func matcherScopesByField() {
        let rule = AutomationRule(
            id: "priority-only", event: .itemMoved,
            matcher: ["field": "priority", "toColumn": "High"],
            action: AutomationAction(startThreadPrompt: "Escalate {{item.title}}.")
        )
        let hit = RuleEngine()
        hit.ingest(event(to: "High", from: "Low", field: "priority"), rules: [rule])
        #expect(hit.pendingProposal != nil)

        // Same value on a different field must not fire the scoped rule.
        let miss = RuleEngine()
        miss.ingest(event(to: "High", from: "Low", field: "status"), rules: [rule])
        #expect(miss.pendingProposal == nil)
    }

    @Test("{{field}} renders the changed field name")
    func rendersFieldToken() {
        let rendered = AutomationRule.render(
            "{{field}}: {{fromColumn}} -> {{toColumn}}",
            event: event(to: "Review", field: "status"))
        #expect(rendered == "status: Todo -> Review")
    }

    // MARK: - 3. End-to-end emission from the store choke-point

    @Test("user drag to Review emits a proposal with the rendered prompt")
    func endToEndEmit() {
        let f = kanbanFixture()
        let engine = RuleEngine()
        f.store.onCanvasEvent = { engine.ingest($0, rules: [reviewRule()]) }

        _ = f.store.patchItem(id: f.itemId, with: ["status": "Review"],
                              myAppId: f.myAppId, componentId: f.compId)

        #expect(engine.pendingProposal != nil)
        #expect(engine.pendingProposal?.prompt == "Review Ship v2.")
    }

    @Test("a non-column patch emits nothing")
    func noEmitOnUnrelatedPatch() {
        let f = kanbanFixture()
        let engine = RuleEngine()
        f.store.onCanvasEvent = { engine.ingest($0, rules: [reviewRule()]) }

        _ = f.store.patchItem(id: f.itemId, with: ["title": "Renamed"],
                              myAppId: f.myAppId, componentId: f.compId)

        #expect(engine.pendingProposal == nil)
    }

    // MARK: - 4. In-flight lock (required guard)

    @Test("in-flight lock drops a second match until the reaction completes")
    func inFlightLock() {
        let engine = RuleEngine()
        let item = UUID()
        let rule = reviewRule()

        engine.ingest(event(to: "Review", from: "Todo", itemId: item), rules: [rule])
        let first = engine.pendingProposal
        #expect(first != nil)
        engine.accept(first!)   // keeps the lock (reaction "running")

        // A fresh transition for the same (rule,item) while in flight → dropped.
        engine.ingest(event(to: "Review", from: "Doing", itemId: item), rules: [rule])
        #expect(engine.pendingProposal == nil)

        // Reaction terminates → the same item can react again.
        engine.complete(ruleId: rule.id, itemId: item)
        engine.ingest(event(to: "Review", from: "Blocked", itemId: item), rules: [rule])
        #expect(engine.pendingProposal != nil)
    }

    // MARK: - 5. Once-per-transition dedupe

    @Test("same transition within the window fires once; a later re-entry fires again")
    func dedupe() {
        var clock = Date()
        let engine = RuleEngine(dedupeWindow: 1.0, now: { clock })
        let item = UUID()
        let rule = reviewRule()
        let ev = event(to: "Review", from: "Todo", itemId: item)

        engine.ingest(ev, rules: [rule])
        let first = engine.pendingProposal
        #expect(first != nil)
        engine.dismiss(first!)   // clears bubble + releases the lock

        // Same transitionId, same window → deduped, no new proposal.
        engine.ingest(ev, rules: [rule])
        #expect(engine.pendingProposal == nil)

        // Past the window → a genuine re-entry fires again.
        clock = clock.addingTimeInterval(2.0)
        engine.ingest(ev, rules: [rule])
        #expect(engine.pendingProposal != nil)
    }

    // MARK: - 6. Self-mutation guard

    @Test("agent-actor move emits no event; user-actor move does")
    func selfMutationGate() {
        let f = kanbanFixture()
        let engine = RuleEngine()
        f.store.onCanvasEvent = { engine.ingest($0, rules: [reviewRule()]) }

        _ = f.store.patchItem(id: f.itemId, with: ["status": "Review"],
                              myAppId: f.myAppId, componentId: f.compId,
                              actor: .agent(toolName: "patchTrackerItems"))
        #expect(engine.pendingProposal == nil)

        _ = f.store.patchItem(id: f.itemId, with: ["status": "Done"],
                              myAppId: f.myAppId, componentId: f.compId, actor: .user)
        // A user move that changes the column still emits (matcher is Review,
        // so Done won't propose — assert via a Done-matching rule instead).
        let engine2 = RuleEngine()
        f.store.onCanvasEvent = { engine2.ingest($0, rules: [
            AutomationRule(id: "r", event: .itemMoved, matcher: ["toColumn": "Review"],
                           action: AutomationAction(startThreadPrompt: "Review {{item.title}}."))
        ]) }
        _ = f.store.patchItem(id: f.itemId, with: ["status": "Review"],
                              myAppId: f.myAppId, componentId: f.compId, actor: .user)
        #expect(engine2.pendingProposal != nil)
    }

    // MARK: - 7. Confirm opt-out

    @Test("confirm:false auto-fires without a bubble; confirm:true surfaces one")
    func confirmOptOut() {
        let auto = RuleEngine()
        auto.ingest(event(to: "Review"), rules: [reviewRule(confirm: false)])
        #expect(auto.pendingProposal == nil)
        #expect(auto.pendingAutoFire != nil)

        let bubble = RuleEngine()
        bubble.ingest(event(to: "Review"), rules: [reviewRule(confirm: true)])
        #expect(bubble.pendingProposal != nil)
        #expect(bubble.pendingAutoFire == nil)
    }
}
