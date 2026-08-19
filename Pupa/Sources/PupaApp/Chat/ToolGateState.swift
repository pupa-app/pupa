import Foundation

/// Per-session record of which tool gates the agent has opened.
///
/// All reads/writes are on @MainActor. Marked @unchecked Sendable so it can
/// be captured in the @Sendable toolFilter closure — all access at the call
/// sites remains under `await MainActor.run { … }`.
///
/// Lifetime: one instance per session — a `(scope, threadId)` ChatViewModel,
/// or a single sub-run (runOneShot / runSubagent / Slack invoke). Never
/// shared: a new thread means a new session key, hence a new VM and a new
/// gate state, so activations can't survive a "New session" or leak between
/// concurrent runs. See [ToolGateIsolationTests].
@MainActor
public final class ToolGateState: @unchecked Sendable {
    private var activated: Set<String> = []
    private var memoriesActivated = false
    private var notificationsActivated = false

    public init() {}

    /// Mark `kind` as activated. Idempotent.
    public func activate(kind: String) { activated.insert(kind) }

    /// Mark the memories tools as activated. Idempotent.
    public func activateMemories() { memoriesActivated = true }

    /// Mark the notifications tools as activated. Idempotent.
    public func activateNotifications() { notificationsActivated = true }

    /// Whether the given kind's tools have been activated this session.
    public func isActivated(kind: String) -> Bool { activated.contains(kind) }

    /// Whether the memories tools have been activated this session.
    public var isMemoriesActivated: Bool { memoriesActivated }

    /// Whether the notifications tools have been activated this session.
    public var isNotificationsActivated: Bool { notificationsActivated }
}
