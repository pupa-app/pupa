import Foundation
import Testing
@testable import PupaApp

/// Tests for the `ask_user_questions` path of `SlackInvoker`: parking a
/// `HumanQuestionRow` batch on a running sub-agent's invocation state,
/// collecting answers, and resuming the suspended continuation on
/// submit / cancel / agent exit.
@MainActor
@Suite("Slack invoker human-in-the-loop")
struct SlackInvokerHITLTests {

    /// Helper: spin up `askQuestions` in an async let and yield until
    /// the parked question is visible on the invocation state. The
    /// call suspends inside `withCheckedContinuation`, so once we
    /// observe `pendingQuestion != nil` the bookkeeping has settled.
    private func awaitParkedQuestion(_ inv: SlackInvoker, agentId: String) async {
        for _ in 0..<100 {
            if inv.activeInvocations[agentId]?.pendingQuestion != nil { return }
            await Task.yield()
        }
    }

    /// Register `agentId` as a root invocation on `inv`'s gate. These
    /// tests only exercise the HITL pathway, not the reentry policy —
    /// each call mints a fresh root (invocationId == treeRoot, no caller).
    @discardableResult
    private func startRootRun(
        _ inv: SlackInvoker,
        agentId: String,
        agentName: String,
        channelId: String = "c1"
    ) -> UUID {
        let id = UUID()
        inv.enter(agentId, agentName: agentName, channelId: channelId,
                  myAppId: UUID(), invocationId: id, caller: .user, treeRoot: id)
        return id
    }

    @Test("askQuestions parks a pending question on the agent's state")
    func askQuestionsParksState() async {
        let inv = SlackInvoker(gate: AgentInvocationGate())
        startRootRun(inv, agentId: "agent-1", agentName: "tutor")

        async let answers = inv.askQuestions(
            agentId: "agent-1",
            rows: [
                HumanQuestionRow(question: "level?", options: ["beginner", "advanced"]),
                HumanQuestionRow(question: "notes?", options: []),
            ]
        )
        await awaitParkedQuestion(inv, agentId: "agent-1")

        let state = inv.activeInvocations["agent-1"]
        #expect(state?.pendingQuestion?.rows.count == 2)
        #expect(state?.pendingQuestion?.rows[0].question == "level?")
        #expect(state?.pendingQuestion?.answers == ["", ""])
        #expect(inv.pendingAnswersComplete(agentId: "agent-1") == false)

        inv.cancelQuestion(agentId: "agent-1")
        _ = await answers
    }

    @Test("setPendingAnswer fills per-row slots; pendingAnswersComplete flips when all are non-empty")
    func setPendingAnswerTracksPerRowState() async {
        let inv = SlackInvoker(gate: AgentInvocationGate())
        startRootRun(inv, agentId: "agent-1", agentName: "tutor")

        async let answers = inv.askQuestions(
            agentId: "agent-1",
            rows: [
                HumanQuestionRow(question: "Q1?", options: []),
                HumanQuestionRow(question: "Q2?", options: []),
            ]
        )
        await awaitParkedQuestion(inv, agentId: "agent-1")

        inv.setPendingAnswer(agentId: "agent-1", rowIndex: 0, value: "a1")
        #expect(inv.activeInvocations["agent-1"]?.pendingQuestion?.answers == ["a1", ""])
        #expect(inv.pendingAnswersComplete(agentId: "agent-1") == false)

        inv.setPendingAnswer(agentId: "agent-1", rowIndex: 1, value: "a2")
        #expect(inv.pendingAnswersComplete(agentId: "agent-1") == true)

        // Whitespace-only doesn't count as filled.
        inv.setPendingAnswer(agentId: "agent-1", rowIndex: 1, value: "   ")
        #expect(inv.pendingAnswersComplete(agentId: "agent-1") == false)

        // Out-of-range writes are silently ignored.
        inv.setPendingAnswer(agentId: "agent-1", rowIndex: 99, value: "junk")
        #expect(inv.activeInvocations["agent-1"]?.pendingQuestion?.answers == ["a1", "   "])

        inv.cancelQuestion(agentId: "agent-1")
        _ = await answers
    }

    @Test("submitAnswers resumes the continuation with the collected answers and clears state")
    func submitAnswersResumesWithAnswers() async {
        let inv = SlackInvoker(gate: AgentInvocationGate())
        startRootRun(inv, agentId: "agent-1", agentName: "tutor")

        async let answers = inv.askQuestions(
            agentId: "agent-1",
            rows: [
                HumanQuestionRow(question: "Q1?", options: []),
                HumanQuestionRow(question: "Q2?", options: []),
            ]
        )
        await awaitParkedQuestion(inv, agentId: "agent-1")

        // Incomplete: submit is a no-op.
        inv.setPendingAnswer(agentId: "agent-1", rowIndex: 0, value: "a1")
        inv.submitAnswers(agentId: "agent-1")
        #expect(inv.activeInvocations["agent-1"]?.pendingQuestion?.rows.count == 2)

        // Complete: submit resumes with answers and clears the slot.
        inv.setPendingAnswer(agentId: "agent-1", rowIndex: 1, value: "a2")
        inv.submitAnswers(agentId: "agent-1")

        let result = await answers
        #expect(result == ["a1", "a2"])
        #expect(inv.activeInvocations["agent-1"]?.pendingQuestion == nil)
    }

    @Test("cancelQuestion resumes the continuation with empty answers and clears state")
    func cancelResumesWithEmptyAnswers() async {
        let inv = SlackInvoker(gate: AgentInvocationGate())
        startRootRun(inv, agentId: "agent-1", agentName: "tutor")

        async let answers = inv.askQuestions(
            agentId: "agent-1",
            rows: [HumanQuestionRow(question: "Q?", options: [])]
        )
        await awaitParkedQuestion(inv, agentId: "agent-1")

        inv.setPendingAnswer(agentId: "agent-1", rowIndex: 0, value: "draft")
        inv.cancelQuestion(agentId: "agent-1")

        let result = await answers
        #expect(result.isEmpty)
        #expect(inv.activeInvocations["agent-1"]?.pendingQuestion == nil)
    }

    @Test("exit drains any leftover parked question so the awaiting task unblocks")
    func exitDrainsLeftoverQuestion() async {
        let inv = SlackInvoker(gate: AgentInvocationGate())
        startRootRun(inv, agentId: "agent-1", agentName: "tutor")

        async let answers = inv.askQuestions(
            agentId: "agent-1",
            rows: [HumanQuestionRow(question: "Q?", options: [])]
        )
        await awaitParkedQuestion(inv, agentId: "agent-1")

        // Simulate a session-error exit without an explicit cancel.
        inv.exit("agent-1")

        let result = await answers
        #expect(result.isEmpty)
        #expect(inv.activeInvocations["agent-1"] == nil)
    }

    @Test("askQuestions on an agent that isn't in flight resumes immediately with empty answers")
    func askQuestionsResumesImmediatelyWhenAgentMissing() async {
        let inv = SlackInvoker(gate: AgentInvocationGate())
        // Never `enter` agent-1.
        let result = await inv.askQuestions(
            agentId: "agent-1",
            rows: [HumanQuestionRow(question: "Q?", options: [])]
        )
        #expect(result.isEmpty)
        #expect(inv.activeInvocations["agent-1"] == nil)
    }

    @Test("Two sub-agents can be parked on questions in parallel; submits resolve independently")
    func parallelAgentsParkIndependently() async {
        let inv = SlackInvoker(gate: AgentInvocationGate())
        startRootRun(inv, agentId: "agent-1", agentName: "tutor")
        startRootRun(inv, agentId: "agent-2", agentName: "coach")

        async let a1 = inv.askQuestions(
            agentId: "agent-1",
            rows: [HumanQuestionRow(question: "Q1?", options: [])]
        )
        async let a2 = inv.askQuestions(
            agentId: "agent-2",
            rows: [HumanQuestionRow(question: "Q2?", options: [])]
        )
        await awaitParkedQuestion(inv, agentId: "agent-1")
        await awaitParkedQuestion(inv, agentId: "agent-2")

        inv.setPendingAnswer(agentId: "agent-1", rowIndex: 0, value: "alice")
        inv.setPendingAnswer(agentId: "agent-2", rowIndex: 0, value: "bob")
        inv.submitAnswers(agentId: "agent-1")
        inv.submitAnswers(agentId: "agent-2")

        let (r1, r2) = await (a1, a2)
        #expect(r1 == ["alice"])
        #expect(r2 == ["bob"])
        #expect(inv.activeInvocations["agent-1"]?.pendingQuestion == nil)
        #expect(inv.activeInvocations["agent-2"]?.pendingQuestion == nil)
    }

    @Test("SlackHITLBridge forwards askQuestions to the invoker keyed by its agentId")
    func bridgeForwardsToInvoker() async {
        let inv = SlackInvoker(gate: AgentInvocationGate())
        startRootRun(inv, agentId: "agent-1", agentName: "tutor")
        let bridge = SlackHITLBridge(agentId: "agent-1", invoker: inv)

        async let answers = bridge.askQuestions([
            HumanQuestionRow(question: "Q?", options: ["yes", "no"]),
        ])
        await awaitParkedQuestion(inv, agentId: "agent-1")

        #expect(inv.activeInvocations["agent-1"]?.pendingQuestion?.rows.first?.question == "Q?")
        inv.setPendingAnswer(agentId: "agent-1", rowIndex: 0, value: "yes")
        inv.submitAnswers(agentId: "agent-1")
        let result = await answers
        #expect(result == ["yes"])
    }

    @Test("SlackHITLBridge with a deallocated invoker returns empty without crashing")
    func bridgeHandlesDeadInvoker() async {
        let bridge: SlackHITLBridge = {
            let inv = SlackInvoker(gate: AgentInvocationGate())
            return SlackHITLBridge(agentId: "agent-1", invoker: inv)
        }()
        // The inner invoker goes out of scope here. The bridge holds it
        // weakly, so the next call resolves to empty answers.
        let result = await bridge.askQuestions([
            HumanQuestionRow(question: "Q?", options: []),
        ])
        #expect(result.isEmpty)
    }
}
