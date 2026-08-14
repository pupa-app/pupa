import Foundation
import Testing
@testable import PupaApp

/// Tests for `AgentStatsStore` (the schema-free per-agent counter bag),
/// `AgentInvocationKey.statKey`, and the gate→stats activity hook.
@MainActor
@Suite("AgentStatsStore")
struct AgentStatsStoreTests {

    @Test("missing key reads as empty")
    func missingKeyEmpty() {
        let stats = AgentStatsStore(seed: [:])
        let s = stats.stat(for: "nope")
        #expect(s.counters.isEmpty)
        #expect(s.lastActiveAt == nil)
        #expect(s.count(AgentStatsStore.delegationsMade) == 0)
    }

    @Test("bump accumulates and stamps lastActiveAt")
    func bumpAccumulates() {
        let stats = AgentStatsStore(seed: [:])
        stats.bump("k", AgentStatsStore.delegationsMade)
        stats.bump("k", AgentStatsStore.delegationsMade, by: 2)
        stats.bump("k", AgentStatsStore.invocationsReceived)
        let s = stats.stat(for: "k")
        #expect(s.count(AgentStatsStore.delegationsMade) == 3)
        #expect(s.count(AgentStatsStore.invocationsReceived) == 1)
        #expect(s.lastActiveAt != nil)
    }

    @Test("persists across instances")
    func persistsRoundTrip() {
        let name = "agentstats-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let writer = AgentStatsStore(defaults: defaults)
        writer.bump("agent-x", AgentStatsStore.delegationsMade, by: 5)
        let reader = AgentStatsStore(defaults: defaults)
        #expect(reader.stat(for: "agent-x").count(AgentStatsStore.delegationsMade) == 5)
    }

    @Test("statKey maps each agent kind")
    func statKeyMapping() {
        let id = UUID()
        #expect(AgentInvocationKey.orchestrator.statKey == "orchestrator")
        #expect(AgentInvocationKey.myApp(id).statKey == id.uuidString)
        #expect(AgentInvocationKey.subagent(myAppId: id, slug: "abc").statKey == "subagent:\(id.uuidString):abc")
    }

    @Test("gate fires onDelegation for nested and session callers, never for .user")
    func gateHookFires() {
        let gate = AgentInvocationGate()
        var fired: [(String, String)] = []
        gate.onDelegation = { caller, target in
            fired.append((caller.statKey, target.statKey))
        }

        // Human-initiated root — nobody to credit, must not fire.
        guard case let .proceed(rootId, root) = gate.decide(caller: nil, target: .orchestrator) else {
            Issue.record("root did not proceed"); return
        }
        gate.enter(invocationId: rootId, target: .orchestrator, caller: .user, treeRoot: root)
        #expect(fired.isEmpty)

        // Nested invocation — the live orchestrator run delegates to a MyApp.
        let appId = UUID()
        guard case let .proceed(childId, childRoot) = gate.decide(caller: rootId, target: .myApp(appId)) else {
            Issue.record("nested did not proceed"); return
        }
        gate.enter(invocationId: childId, target: .myApp(appId), caller: .agent(rootId), treeRoot: childRoot)
        #expect(fired.count == 1)
        #expect(fired.first?.0 == "orchestrator")
        #expect(fired.first?.1 == appId.uuidString)
    }

    /// The bug this suite missed: a chat panel owns no forest node, so its
    /// first-level delegations used to record nothing at all.
    @Test("session caller is credited while staying a tree root")
    func sessionCallerIsCredited() {
        let gate = AgentInvocationGate()
        var fired: [(String, String)] = []
        gate.onDelegation = { caller, target in
            fired.append((caller.statKey, target.statKey))
        }

        let appId = UUID()
        guard case let .proceed(id, root) = gate.decide(caller: nil, target: .myApp(appId)) else {
            Issue.record("did not proceed"); return
        }
        gate.enter(invocationId: id, target: .myApp(appId), caller: .session(.orchestrator), treeRoot: root)

        #expect(fired.count == 1)
        #expect(fired.first?.0 == "orchestrator")
        #expect(fired.first?.1 == appId.uuidString)
        // Still a root: no parent, tree rooted at itself.
        #expect(gate.activeInvocations[id]?.parentInvocationId == nil)
        #expect(gate.activeInvocations[id]?.treeRootInvocationId == id)
    }

    @Test("agent caller whose run already exited credits nobody")
    func exitedAgentCallerCreditsNobody() {
        let gate = AgentInvocationGate()
        var fired = 0
        gate.onDelegation = { _, _ in fired += 1 }

        let appId = UUID()
        guard case let .proceed(id, root) = gate.decide(caller: nil, target: .myApp(appId)) else {
            Issue.record("did not proceed"); return
        }
        gate.enter(invocationId: id, target: .myApp(appId), caller: .agent(UUID()), treeRoot: root)
        #expect(fired == 0)
    }
}
