import Foundation

/// Lets the `ask_user_questions` frontend tool render a question panel
/// inside the chat surface and await the user's submission. The handler
/// in [AppTools.swift](AppTools.swift) takes a bridge at registration
/// time; `ChatViewModel` is the only conformer in the app and provides
/// the storage + UI plumbing for the suspended call.
///
/// Suspending on the bridge keeps the AGUIKit dispatch loop in
/// `AgentSession.dispatchFrontendTools` parked until the user submits —
/// `interrupt()` on the backend stays paused, the model only re-runs
/// after we POST the resume with answers, and there's no separate
/// `humanQuestionsRequired` session event.
@MainActor
public protocol HumanInTheLoopBridge: AnyObject, Sendable {
    /// Render a panel for the given questions, await the user's Submit,
    /// return one answer per row in input order. Cancellation of the
    /// enclosing task resumes with empty answers so the agent stops
    /// waiting and the bubble is cleared.
    func askQuestions(_ questions: [HumanQuestionRow]) async -> [String]

    /// Render a card prompting the user to approve or deny a pending shell
    /// command before it executes on the backend host. Returns
    /// `(approved: Bool, remember: Bool)` — `remember` is true when the
    /// user wants to pre-approve the exact command string for the rest of
    /// the session. Cancellation resumes with `(false, false)`.
    func requestShellApproval(command: String) async -> (approved: Bool, remember: Bool)
}
