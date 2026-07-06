import Foundation
import Testing
@testable import PupaApp

/// Slack-specific UI substrate tests for `SlackInvoker`. The
/// reentrancy / busy / chain-depth policy lives on
/// `AgentInvocationGate` now and is covered by
/// `AgentInvocationGateTests`; this file pins the Slack-only
/// behaviour: per-agent `activeInvocations` state, channel grouping,
/// and the tool-call lifecycle hooks that `SlackView` reads on every
/// render.
@MainActor
@Suite("Slack invoker UI state")
struct SlackInvokerReentrancyTests {

    private let myAppId = UUID()

    /// Convenience: decide(caller: nil) then invoker.enter. Returns the invocationId.
    @discardableResult
    func enterSlack(_ inv: SlackInvoker, agentId: String, agentName: String, channelId: String) -> UUID {
        let gate = inv.gate
        guard case let .proceed(id, root) = gate.decide(
            caller: nil, target: .subagent(myAppId: myAppId, slug: agentId)
        ) else {
            Issue.record("Expected .proceed")
            return UUID()
        }
        return inv.enter(agentId, agentName: agentName, channelId: channelId,
                         myAppId: myAppId, invocationId: id, caller: nil, treeRoot: root)
    }

    @Test("activeInvocations tracks live agent state per channel")
    func activeInvocationsByChannel() {
        let inv = SlackInvoker(gate: AgentInvocationGate())
        enterSlack(inv, agentId: "a1", agentName: "marketing", channelId: "planning")
        enterSlack(inv, agentId: "a2", agentName: "dev", channelId: "planning")
        enterSlack(inv, agentId: "a3", agentName: "research", channelId: "design")
        let planning = inv.invocations(forChannel: "planning")
        #expect(planning.map(\.agentName) == ["dev", "marketing"])
        let design = inv.invocations(forChannel: "design")
        #expect(design.map(\.agentName) == ["research"])
        inv.exit("a2")
        #expect(inv.invocations(forChannel: "planning").map(\.agentName) == ["marketing"])
    }

    @Test("isBusy reflects activeInvocations membership")
    func isBusyReflectsState() {
        let inv = SlackInvoker(gate: AgentInvocationGate())
        #expect(inv.isBusy("agent-1") == false)
        enterSlack(inv, agentId: "agent-1", agentName: "marketing", channelId: "c1")
        #expect(inv.isBusy("agent-1") == true)
        #expect(inv.isBusy("agent-2") == false)
        inv.exit("agent-1")
        #expect(inv.isBusy("agent-1") == false)
    }

    @Test("recordToolCallStart/Finish patches the matching entry to .done or .failed")
    func toolCallLifecycle() {
        let inv = SlackInvoker(gate: AgentInvocationGate())
        enterSlack(inv, agentId: "a1", agentName: "marketing", channelId: "c1")
        inv.recordToolCallStart(agentId: "a1", id: "t1", name: "renderTracker")
        inv.recordToolCallStart(agentId: "a1", id: "t1", name: "renderTracker") // dedup
        #expect(inv.activeInvocations["a1"]?.toolEntries.count == 1)
        #expect(inv.activeInvocations["a1"]?.toolEntries.first?.state == .pending)

        inv.recordToolCallFinish(
            agentId: "a1",
            id: "t1",
            name: "renderTracker",
            argsJSON: "{}",
            resultText: "{\"ok\":true}",
            failed: false
        )
        #expect(inv.activeInvocations["a1"]?.toolEntries.first?.state == .done)

        inv.recordToolCallStart(agentId: "a1", id: "t2", name: "broken")
        inv.recordToolCallFinish(
            agentId: "a1",
            id: "t2",
            name: "broken",
            argsJSON: "{}",
            resultText: "{\"ok\":false}",
            failed: true
        )
        #expect(inv.activeInvocations["a1"]?.toolEntries.last?.state == .failed)
    }
}
