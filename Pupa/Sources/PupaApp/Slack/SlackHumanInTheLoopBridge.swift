import Foundation

/// `HumanInTheLoopBridge` implementation for a Slack sub-agent run.
/// Forwards `ask_user_questions` calls to its owning `SlackInvoker`,
/// which parks the question against the sub-agent's invocation state so
/// `SlackView` can render the question card inline in the channel pane.
///
/// One bridge instance per sub-agent invocation, created in
/// `ChatSessionCoordinator.invokeSlackAgent` and registered on that
/// session's `ToolRegistry`. The registration holds the bridge weakly,
/// so a strong reference must live for the duration of the run — the
/// coordinator captures it in a local `let` for that purpose.
@MainActor
public final class SlackHITLBridge: HumanInTheLoopBridge {
    public let agentId: String
    private weak var invoker: SlackInvoker?

    public init(agentId: String, invoker: SlackInvoker) {
        self.agentId = agentId
        self.invoker = invoker
    }

    public func askQuestions(_ questions: [HumanQuestionRow]) async -> [String] {
        guard let invoker else { return [] }
        return await invoker.askQuestions(agentId: agentId, rows: questions)
    }

    public func requestShellApproval(command: String) async -> (approved: Bool, remember: Bool) {
        guard let invoker else { return (false, false) }
        return await invoker.requestShellApproval(agentId: agentId, command: command)
    }
}
