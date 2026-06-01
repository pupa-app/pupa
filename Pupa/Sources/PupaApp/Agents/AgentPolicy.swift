import Foundation

// MARK: - AgentPayload

/// A snapshot of everything needed for one agent turn:
/// the merged system-prompt string, the memory store scoped to this
/// agent's root, and a tool-filter predicate.
///
/// Built by `AgentPolicy.payload(for:store:)` and threaded through
/// `ChatViewModel.send(…)`.
public struct AgentPayload: Sendable {
    /// Fully-merged system prompt: type instructions + AGENTS.md content
    /// from the agent's own memory root (or the hardcoded fallback).
    public let systemPrompt: String
    /// Memory store rooted at this agent's private folder.
    public let memory: MemoryStore
    /// Tool-name filter; `true` → tool is available to this agent.
    public let toolFilter: @Sendable (String) -> Bool

    public init(
        systemPrompt: String,
        memory: MemoryStore,
        toolFilter: @escaping @Sendable (String) -> Bool
    ) {
        self.systemPrompt = systemPrompt
        self.memory = memory
        self.toolFilter = toolFilter
    }
}

// MARK: - AgentPolicy

/// Determines what an agent can do and how its payload is assembled.
///
/// Each concrete agent kind — orchestrator, MyApp, Slack — provides one
/// conformance.  `payload(for:store:)` is the only required method;
/// `toolsExposedTo` and `canInvoke` layer on A2A access-control.
///
/// ## Adding a new agent kind
/// 1. Create `<Kind>Policy.swift` in `Sources/PupaApp/Agents/`.
/// 2. Conform to `AgentPolicy`.
/// 3. Add a case to `AgentDispatcher.policy(for:)`.
public protocol AgentPolicy: Sendable {
    /// Build the `AgentPayload` for one agent turn.
    /// Runs on MainActor so it can read `store.myApps`.
    @MainActor
    func payload(for scope: ChatScope, store: MyAppStore) async -> AgentPayload

    /// Tools exposed to `caller` in an A2A invocation.
    /// Returns `nil` when `caller == nil` (user-facing; no A2A restriction).
    func toolsExposedTo(caller: ChatScope?) -> Set<String>?

    /// Whether `callerScope` is allowed to invoke this agent at all.
    /// Default: `true` for all callers.
    func canInvoke(from callerScope: ChatScope?) -> Bool
}

public extension AgentPolicy {
    func canInvoke(from callerScope: ChatScope?) -> Bool { true }
}

