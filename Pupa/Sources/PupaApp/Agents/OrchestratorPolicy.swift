import Foundation

// MARK: - OrchestratorPolicy

/// `AgentPolicy` for the orchestrator (`.memory` scope).
///
/// Memory root:  `<sandbox>/orchestrator/`
/// System prompt: `orchestrator/AGENTS.md` (or hardcoded fallback).
/// Tools: memory FS + HITL + `orchestratorToolNames` + tool-gated
///        notifications. Never canvas tools.
public struct OrchestratorPolicy: AgentPolicy {

    public init() {}

    // MARK: AgentPolicy

    @MainActor
    public func payload(for scope: ChatScope, store: MyAppStore) async -> AgentPayload {
        let memory = MemoryStore(rootOverride: MemoryStore.orchestratorRoot())
        let systemPrompt = buildSystemPrompt(memory: memory)
        let toolNames = ChatViewModel.allowedToolNames(scope: .memory, store: store, toolGateState: ToolGateState())
        return AgentPayload(
            systemPrompt: systemPrompt,
            memory: memory,
            toolFilter: { toolNames.contains($0) }
        )
    }

    // MARK: A2A surface

    /// The orchestrator is the root; it is never invoked by other agents.
    public func toolsExposedTo(caller: ChatScope?) -> Set<String>? { nil }

    /// Only the user (nil caller) may address the orchestrator.
    public func canInvoke(from callerScope: ChatScope?) -> Bool {
        callerScope == nil
    }

    // MARK: Private

    @MainActor
    public func buildSystemPrompt(memory: MemoryStore) -> String {
        let agentsMd = (try? memory.readFile(path: "AGENTS.md"))?.content
        return agentsMd.map {
            "Orchestrator instructions (AGENTS.md):\n\n\($0)"
        } ?? """
            ORCHESTRATOR scope — no canvas here. Surfaces: memories FileSystem + \
            list/create/renameMyApp + invokeMyAppAgent(myAppId, prompt) to \
            delegate one-shot tasks (sub-run mutates that canvas + returns \
            summary). Fan out by emitting multiple invokeMyAppAgent calls \
            in one assistant message. No direct canvas calls from here.
            """
    }
}
