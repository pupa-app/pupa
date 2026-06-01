import Foundation

/// Per-session record of which tool-skill gates the agent has opened.
///
/// All reads/writes are on @MainActor. Marked @unchecked Sendable so it can
/// be captured in the @Sendable toolFilter closure — all access at the call
/// sites remains under `await MainActor.run { … }`.
///
/// Lifetime: owned by ChatViewModel, discarded with the session.
/// ChatViewModel.newThread() calls reset() so skills don't survive a session
/// reset, consistent with canvas state behaviour.
@MainActor
public final class SkillState: @unchecked Sendable {
    private var activated: Set<String> = []
    private var memoriesActivated = false
    private var notificationsActivated = false

    public init() {}

    /// Mark `kind` as activated. Idempotent.
    public func activate(kind: String) { activated.insert(kind) }

    /// Mark the memories skill as activated. Idempotent.
    public func activateMemories() { memoriesActivated = true }

    /// Mark the notifications skill as activated. Idempotent.
    public func activateNotifications() { notificationsActivated = true }

    /// Whether the given kind's skill has been activated this session.
    public func isActivated(kind: String) -> Bool { activated.contains(kind) }

    /// Whether the memories skill has been activated this session.
    public var isMemoriesActivated: Bool { memoriesActivated }

    /// Whether the notifications skill has been activated this session.
    public var isNotificationsActivated: Bool { notificationsActivated }

    /// Reset all activations — called by ChatViewModel.newThread().
    public func reset() {
        activated.removeAll()
        memoriesActivated = false
        notificationsActivated = false
    }
}
