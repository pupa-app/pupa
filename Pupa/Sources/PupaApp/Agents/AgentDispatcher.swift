import Foundation

// MARK: - AgentDispatcher

/// Maps a `ChatScope` to its `AgentPolicy` and builds an `AgentPayload`.
///
/// `ChatViewModel` calls `payload(for:store:)` once per user turn, before
/// streaming starts.  The dispatcher itself is stateless — policy objects
/// are value types that read `store.myApps` on demand.
///
/// ## Adding a new agent kind
/// Implement `AgentPolicy` and add a case to `policy(for:)` below.
public struct AgentDispatcher: Sendable {

    public static let shared = AgentDispatcher()
    public init() {}

    /// Look up the policy for `scope`.
    public func policy(for scope: ChatScope) -> any AgentPolicy {
        switch scope {
        case .memory:
            return OrchestratorPolicy()
        case .myApp(let id):
            return MyAppPolicy(myAppId: id)
        }
    }

    /// Convenience: resolve the policy and immediately build a payload.
    @MainActor
    public func payload(for scope: ChatScope, store: MyAppStore) async -> AgentPayload {
        await policy(for: scope).payload(for: scope, store: store)
    }
}
