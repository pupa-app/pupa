import Foundation
import Observation

/// App-layer glue between the `CanvasEvent` stream and the UI. Owns the
/// `RuleEngine`, re-stamps the reentrancy flag from its own spawned threads,
/// and dispatches proposals through the injected `dispatch` closure (which
/// AppView wires to the notification-tap "propose a chat" bridge).
///
/// Decoupled by design: it knows nothing about SwiftUI navigation or the
/// tour bridge — only `rulesProvider` (scope → rules) and `dispatch`
/// (proposal → spawned threadId). That keeps the tested engine free of UI.
@MainActor
@Observable
public final class AutomationCoordinator {
    private let engine = RuleEngine()
    private let rulesProvider: (UUID) -> [AutomationRule]
    private let dispatch: (AutomationProposal) -> String?

    /// Threads this coordinator spawned — events they cause are tagged
    /// `automationOrigin` so a reaction can't re-trigger its own rule.
    private var spawnedThreadIds: Set<String> = []
    /// Reaction thread → the lock it holds, so termination clears it.
    private var lockByThread: [String: (ruleId: String, itemId: UUID)] = [:]

    /// Hung-run fallback: a reaction that never signals termination clears
    /// its lock after this window so it can't wedge the rule forever
    /// (issue #209 guard 1). Test hook.
    static var lockTimeout: Duration = .seconds(600)

    public init(
        rulesProvider: @escaping (UUID) -> [AutomationRule],
        dispatch: @escaping (AutomationProposal) -> String?
    ) {
        self.rulesProvider = rulesProvider
        self.dispatch = dispatch
    }

    /// Ingest one canvas event: tag reentrancy, match, dispatch.
    public func handle(_ event: CanvasEvent) {
        var ev = event
        if let tid = ev.originThreadId, spawnedThreadIds.contains(tid) {
            ev.automationOrigin = true
        }
        let proposals = engine.evaluate(event: ev, rules: rulesProvider(ev.myAppId))
        for p in proposals {
            guard let threadId = dispatch(p) else {
                engine.clearLock(ruleId: p.ruleId, itemId: p.itemId)   // dispatch refused → don't hold the lock
                continue
            }
            spawnedThreadIds.insert(threadId)
            lockByThread[threadId] = (p.ruleId, p.itemId)
            scheduleTimeout(threadId)
        }
    }

    /// A reaction reached a terminal state (thread closed / dismissed /
    /// failed / timed out) — release its in-flight lock.
    public func reactionTerminated(threadId: String) {
        guard let key = lockByThread.removeValue(forKey: threadId) else { return }
        engine.clearLock(ruleId: key.ruleId, itemId: key.itemId)
    }

    private func scheduleTimeout(_ threadId: String) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.lockTimeout)
            self?.reactionTerminated(threadId: threadId)
        }
    }
}
