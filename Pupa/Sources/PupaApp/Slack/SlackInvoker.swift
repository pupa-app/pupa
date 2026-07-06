import Foundation
import Observation

/// Slack-side UI substrate for in-flight sub-agent runs. Owns the
/// per-agent tool-call entries, parked HITL questions, and parked
/// shell-approval prompts that `SlackView` renders. Reentrancy /
/// busy / chain-depth policy lives on the shared
/// `AgentInvocationGate` — call sites consult that directly with a
/// `.slack(agentId:)` key, then bracket the run with `enter(_:…)` /
/// `exit(_:)` here to set up and tear down `activeInvocations`.
///
/// `enter` / `exit` pair with the gate by calling
/// `gate.enter(invocationId:target:caller:treeRoot:)` /
/// `gate.exit(invocationId)` so the Slack lifecycle is a single
/// bundled operation at the call site; the coordinator never touches
/// the gate directly for a Slack key.
@MainActor
@Observable
public final class SlackInvoker {
    /// Shared cross-scope policy state. Two SlackInvokers built with
    /// the same `gate` participate in a single invocation graph —
    /// reentrancy across MyApp and Slack sub-runs is detected.
    public let gate: AgentInvocationGate

    /// Per-agent live invocation snapshot — what tools the agent
    /// has called so far in this run. Cleared on `exit`. Read by
    /// `SlackView` to render the per-agent thinking bubble. Its
    /// `keys` also serve as the source of truth for "which Slack
    /// agent is currently in flight" — there's no separate `Set` to
    /// keep in sync.
    public private(set) var activeInvocations: [String: SlackInvocationState] = [:]

    /// Continuations parked by `askQuestions(agentId:rows:)` for sub-agents
    /// currently waiting on the user's reply. Stored on the invoker (a
    /// class) rather than inside the `SlackInvocationState` struct so the
    /// continuation isn't copied around with the observed value; each entry
    /// must be resumed exactly once via `submitAnswers` or `cancelQuestion`.
    private var pendingContinuations: [String: CheckedContinuation<[String], Never>] = [:]
    /// Continuations parked by `requestShellApproval(agentId:command:)`. Same
    /// ownership rationale as `pendingContinuations` — stored on the invoker.
    private var pendingShellApprovalContinuations: [String: CheckedContinuation<(Bool, Bool), Never>] = [:]

    public init(gate: AgentInvocationGate) {
        self.gate = gate
    }

    /// What `invokeSlackAgent` returns after a run. `.completed`
    /// carries the agent's final assistant text (already posted to
    /// the channel by the coordinator). The error cases let the
    /// caller render a UX-friendly note without inspecting the
    /// underlying gate state.
    public enum InvocationOutcome: Equatable, Sendable {
        case completed(text: String, postedMessageId: String?)
        case reentrant(targetName: String)
        case busy(targetName: String)
        case maxDepthExceeded(targetName: String, depth: Int)
        case budgetExhausted(targetName: String, exhaustedAfter: Int)
        case failed(error: String)
    }

    /// Record a Slack agent run in the shared invocation forest and
    /// stash the live `SlackInvocationState` for `SlackView`. The
    /// `invocationId`, `caller`, and `treeRoot` come from the
    /// `.proceed` decision the coordinator already obtained from the
    /// gate — this method just performs the bookkeeping. Returns the
    /// `invocationId` for convenience so the caller can keep using
    /// the same value as a `caller` parameter when wiring nested
    /// tool calls. Paired with `exit(_:)` — always via `defer` at
    /// the call site so a thrown error / cancellation still releases
    /// the slot.
    @discardableResult
    public func enter(
        _ agentId: String,
        agentName: String,
        channelId: String,
        myAppId: UUID,
        invocationId: UUID,
        caller: UUID?,
        treeRoot: UUID
    ) -> UUID {
        gate.enter(
            invocationId: invocationId,
            target: .subagent(myAppId: myAppId, slug: agentId),
            caller: caller,
            treeRoot: treeRoot
        )
        activeInvocations[agentId] = SlackInvocationState(
            invocationId: invocationId,
            agentId: agentId,
            agentName: agentName,
            channelId: channelId
        )
        return invocationId
    }

    public func exit(_ agentId: String) {
        if let state = activeInvocations.removeValue(forKey: agentId) {
            gate.exit(state.invocationId)
        }
        // Defensive drain: if the run is exiting while a question is
        // still parked (e.g. the session errored mid-interrupt), the
        // continuation MUST be resumed or the awaiting Task leaks.
        if let cont = pendingContinuations.removeValue(forKey: agentId) {
            cont.resume(returning: [])
        }
    }

    /// Invocation id of the currently-active run for `agentId`, or
    /// nil if none. Used by tool closures bound to a sub-agent's
    /// session that need to pass their own id as `caller` into a
    /// nested coordinator call (e.g. `slackPostMessage` →
    /// `invokeSlackAgent`).
    public func currentInvocationId(agentId: String) -> UUID? {
        activeInvocations[agentId]?.invocationId
    }

    /// Note that the running agent has explicitly posted a message
    /// via the `slackPostMessage` tool. The coordinator reads this
    /// at run-end to decide whether to auto-post the final
    /// assistant text — if the agent already spoke explicitly,
    /// auto-post would duplicate the reply.
    public func markMessagePosted(agentId: String) {
        guard var state = activeInvocations[agentId] else { return }
        state.messagesPosted += 1
        activeInvocations[agentId] = state
    }

    /// True iff the agent has called `slackPostMessage` at least
    /// once during its current run.
    public func hasExplicitlyPosted(agentId: String) -> Bool {
        (activeInvocations[agentId]?.messagesPosted ?? 0) > 0
    }

    /// Append a freshly-started tool call to the agent's live state.
    /// Called from the coordinator on every `.toolCallStarted`.
    public func recordToolCallStart(agentId: String, id: String, name: String) {
        guard var state = activeInvocations[agentId] else { return }
        // Dedup — `.toolCallStarted` can re-emit on interrupt-driven
        // resumes for the same toolCallId. Only insert if new.
        if !state.toolEntries.contains(where: { $0.id == id }) {
            state.toolEntries.append(ToolCallEntry(id: id, name: name, state: .pending))
            activeInvocations[agentId] = state
        }
    }

    /// Patch the matching entry to `.done` / `.failed` and stash
    /// the args + result JSON. Called from the coordinator on every
    /// `.toolCallFinished`. If the entry doesn't exist yet (race),
    /// the call inserts a fresh one in its final state.
    public func recordToolCallFinish(
        agentId: String,
        id: String,
        name: String,
        argsJSON: String,
        resultText: String,
        failed: Bool
    ) {
        guard var state = activeInvocations[agentId] else { return }
        let nextState: ToolCallEntry.State = failed ? .failed : .done
        if let idx = state.toolEntries.firstIndex(where: { $0.id == id }) {
            state.toolEntries[idx].argsJSON = argsJSON
            state.toolEntries[idx].resultText = resultText
            state.toolEntries[idx].state = nextState
        } else {
            state.toolEntries.append(ToolCallEntry(
                id: id,
                name: name,
                argsJSON: argsJSON,
                resultText: resultText,
                state: nextState
            ))
        }
        activeInvocations[agentId] = state
    }

    // MARK: - Human-in-the-loop (ask_user_questions for sub-agents)

    /// Park a `HumanQuestionRow` batch against the running agent's
    /// invocation state and suspend until the user submits via
    /// `submitAnswers(agentId:)` or cancels via `cancelQuestion(agentId:)`.
    /// Backs the `ask_user_questions` frontend tool when invoked by a
    /// Slack sub-agent — `SlackHITLBridge` forwards every call here.
    ///
    /// If the agent isn't in flight (e.g. its session already exited),
    /// resumes immediately with empty answers so the dispatch loop
    /// unblocks instead of hanging on a question nobody can answer.
    public func askQuestions(agentId: String, rows: [HumanQuestionRow]) async -> [String] {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
                guard var state = activeInvocations[agentId] else {
                    continuation.resume(returning: [])
                    return
                }
                state.pendingQuestion = SlackPendingQuestion(
                    rows: rows,
                    answers: Array(repeating: "", count: rows.count)
                )
                activeInvocations[agentId] = state
                pendingContinuations[agentId] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelQuestion(agentId: agentId)
            }
        }
    }

    /// Write a per-row answer into the parked question. Out-of-range
    /// indices and writes against an agent with no parked question are
    /// silently ignored — the view layer mirrors `ChatViewModel.setPendingAnswer`.
    public func setPendingAnswer(agentId: String, rowIndex: Int, value: String) {
        guard var state = activeInvocations[agentId],
              var q = state.pendingQuestion,
              q.answers.indices.contains(rowIndex) else { return }
        q.answers[rowIndex] = value
        state.pendingQuestion = q
        activeInvocations[agentId] = state
    }

    /// True iff every row of the parked question has a non-whitespace
    /// answer. Drives the Submit button's enable state.
    public func pendingAnswersComplete(agentId: String) -> Bool {
        guard let q = activeInvocations[agentId]?.pendingQuestion else { return false }
        return q.answers.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Resume the parked continuation with the collected answers and
    /// clear the pending-question slot. No-op when answers are incomplete
    /// or no question is parked — mirrors `ChatViewModel.submitInterruptAnswers`.
    public func submitAnswers(agentId: String) {
        guard pendingAnswersComplete(agentId: agentId),
              var state = activeInvocations[agentId],
              let q = state.pendingQuestion,
              let continuation = pendingContinuations.removeValue(forKey: agentId) else {
            return
        }
        let answers = q.answers
        state.pendingQuestion = nil
        activeInvocations[agentId] = state
        continuation.resume(returning: answers)
    }

    /// Resume the parked continuation with an empty answer list so the
    /// agent's dispatch loop unblocks (the model then sees an empty
    /// answer payload and decides how to proceed). Used both by an
    /// explicit user cancel and by task cancellation propagated via
    /// `withTaskCancellationHandler` inside `askQuestions`.
    public func cancelQuestion(agentId: String) {
        guard let continuation = pendingContinuations.removeValue(forKey: agentId) else { return }
        if var state = activeInvocations[agentId] {
            state.pendingQuestion = nil
            activeInvocations[agentId] = state
        }
        continuation.resume(returning: [])
    }

    /// Park a shell-approval request for `agentId` — `SlackView` renders
    /// an inline approval card; the caller suspends until the user decides.
    public func requestShellApproval(agentId: String, command: String) async -> (Bool, Bool) {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Bool), Never>) in
                guard var state = activeInvocations[agentId] else {
                    continuation.resume(returning: (false, false))
                    return
                }
                state.pendingShellApproval = SlackPendingShellApproval(command: command)
                activeInvocations[agentId] = state
                pendingShellApprovalContinuations[agentId] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelShellApproval(agentId: agentId) }
        }
    }

    /// Resume with the user's decision and clear the parked approval state.
    public func approveShellCommand(agentId: String, remember: Bool) {
        guard let continuation = pendingShellApprovalContinuations.removeValue(forKey: agentId) else { return }
        if var state = activeInvocations[agentId] {
            state.pendingShellApproval = nil
            activeInvocations[agentId] = state
        }
        continuation.resume(returning: (true, remember))
    }

    public func denyShellCommand(agentId: String) {
        guard let continuation = pendingShellApprovalContinuations.removeValue(forKey: agentId) else { return }
        if var state = activeInvocations[agentId] {
            state.pendingShellApproval = nil
            activeInvocations[agentId] = state
        }
        continuation.resume(returning: (false, false))
    }

    public func cancelShellApproval(agentId: String) {
        guard let continuation = pendingShellApprovalContinuations.removeValue(forKey: agentId) else { return }
        if var state = activeInvocations[agentId] {
            state.pendingShellApproval = nil
            activeInvocations[agentId] = state
        }
        continuation.resume(returning: (false, false))
    }

    /// True iff `agentId` is in flight. Drives per-row spinners in
    /// the Slack sidebar.
    public func isBusy(_ agentId: String) -> Bool {
        activeInvocations[agentId] != nil
    }

    /// Snapshot of every in-flight invocation against `channelId`.
    /// `SlackView` calls this on every render to find which
    /// thinking bubbles to show.
    public func invocations(forChannel channelId: String) -> [SlackInvocationState] {
        activeInvocations.values
            .filter { $0.channelId == channelId }
            .sorted { $0.agentName < $1.agentName }
    }
}

/// Live snapshot of one in-flight Slack agent run. Mutated by the
/// coordinator as `SessionEvent`s flow; read by `SlackView` to
/// render the per-agent thinking bubble.
public struct SlackInvocationState: Equatable {
    /// Forest node id minted at `decide(...)` time and threaded
    /// through `enter(...)`. Sub-agent tool closures read it via
    /// `SlackInvoker.currentInvocationId(agentId:)` so nested
    /// `invokeSlackAgent` calls can pass it as `caller`.
    public let invocationId: UUID
    public let agentId: String
    public let agentName: String
    public let channelId: String
    public var toolEntries: [ToolCallEntry] = []
    /// Count of explicit `slackPostMessage` tool calls the agent
    /// has made during this run. Drives the auto-post-suppression
    /// logic in the coordinator.
    public var messagesPosted: Int = 0
    /// Non-nil while the sub-agent is parked on an `ask_user_questions`
    /// interrupt awaiting the user's reply. The view renders an inline
    /// yellow question card in the channel pane when set; writes flow
    /// through `SlackInvoker.setPendingAnswer` / `submitAnswers` /
    /// `cancelQuestion`.
    public var pendingQuestion: SlackPendingQuestion? = nil
    /// Non-nil while the sub-agent is parked on a `request_shell_approval`
    /// interrupt awaiting the user's Approve / Deny decision.
    public var pendingShellApproval: SlackPendingShellApproval? = nil

    public init(
        invocationId: UUID,
        agentId: String,
        agentName: String,
        channelId: String,
        toolEntries: [ToolCallEntry] = [],
        messagesPosted: Int = 0,
        pendingQuestion: SlackPendingQuestion? = nil,
        pendingShellApproval: SlackPendingShellApproval? = nil
    ) {
        self.invocationId = invocationId
        self.agentId = agentId
        self.agentName = agentName
        self.channelId = channelId
        self.toolEntries = toolEntries
        self.messagesPosted = messagesPosted
        self.pendingQuestion = pendingQuestion
        self.pendingShellApproval = pendingShellApproval
    }
}

/// The view of a parked `ask_user_questions` call inside a Slack
/// sub-agent's invocation state. `rows` mirrors the request the model
/// sent; `answers` carries the user's per-row input as they fill it in.
/// The view of a parked `request_shell_approval` call inside a Slack
/// sub-agent's invocation state. `SlackView` renders an inline approval card.
public struct SlackPendingShellApproval: Equatable, Sendable {
    public var command: String
    public init(command: String) { self.command = command }
}

public struct SlackPendingQuestion: Equatable, Sendable {
    public var rows: [HumanQuestionRow]
    public var answers: [String]

    public init(rows: [HumanQuestionRow], answers: [String]) {
        self.rows = rows
        self.answers = answers
    }
}
