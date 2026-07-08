import Foundation
import Testing
@testable import PupaApp

/// The generic `.subagent(myAppId:slug:)` invocation key participates in the
/// shared gate exactly like `.myApp` — reentrancy, sibling allowance, and
/// depth all resolve per (myAppId, slug).
@MainActor
@Suite("Subagent gate key")
struct SubagentGateKeyTests {

    @discardableResult
    private func enter(_ gate: AgentInvocationGate, caller: UUID?, target: AgentInvocationKey) -> UUID {
        guard case let .proceed(id, root) = gate.decide(caller: caller, target: target) else {
            Issue.record("Expected .proceed for \(target)"); return UUID()
        }
        gate.enter(invocationId: id, target: target, caller: caller, treeRoot: root)
        return id
    }

    @Test("A subagent re-entering itself down the chain is rejected")
    func reentrantSubagent() {
        let gate = AgentInvocationGate()
        let app = UUID()
        let a: AgentInvocationKey = .subagent(myAppId: app, slug: "coach")
        let b: AgentInvocationKey = .subagent(myAppId: app, slug: "scout")
        let rootId = enter(gate, caller: nil, target: a)          // coach (root)
        let bId = enter(gate, caller: rootId, target: b)          // coach → scout
        // scout invoking coach again re-enters an ancestor → rejected.
        guard case .reentrant = gate.decide(caller: bId, target: a) else {
            Issue.record("Expected .reentrant when scout re-invokes coach"); return
        }
    }

    @Test("Same slug in two different MyApps does not collide")
    func slugDisambiguatedByMyApp() {
        let gate = AgentInvocationGate()
        let app1 = UUID(), app2 = UUID()
        let a1: AgentInvocationKey = .subagent(myAppId: app1, slug: "coach")
        let a2: AgentInvocationKey = .subagent(myAppId: app2, slug: "coach")
        let rootId = enter(gate, caller: nil, target: a1)
        // Same slug, different myApp → not an ancestor, must proceed.
        guard case .proceed = gate.decide(caller: rootId, target: a2) else {
            Issue.record("Expected .proceed for same slug in a different myApp"); return
        }
    }

    @Test("statKey / wireValue encode both myAppId and slug")
    func keyEncoding() {
        let app = UUID()
        let key: AgentInvocationKey = .subagent(myAppId: app, slug: "coach")
        #expect(key.statKey == "subagent:\(app.uuidString):coach")
        #expect(key.wireValue == "subagent:\(app.uuidString):coach")
    }
}
