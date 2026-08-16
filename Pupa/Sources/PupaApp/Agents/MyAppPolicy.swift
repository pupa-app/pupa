import Foundation

// MARK: - MyAppPolicy

/// `AgentPolicy` for an active MyApp (`.myApp(id)` scope).
///
/// Memory root:  `<sandbox>/myapps/<name>/`
/// System prompt: `<root>/pupa/AGENTS.md` (or type-fragment fallback).
/// Tools: type's resolved tool names + HITL + tool-gated memory /
///        notifications / per-kind tools. Never orchestrator tools.
public struct MyAppPolicy: AgentPolicy {

    public let myAppId: UUID

    public init(myAppId: UUID) {
        self.myAppId = myAppId
    }

    // MARK: AgentPolicy

    @MainActor
    public func payload(for scope: ChatScope, store: MyAppStore) async -> AgentPayload {
        let myApp = store.myApps.first(where: { $0.id == myAppId })
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: myAppId))
        let systemPrompt = buildSystemPrompt(myApp: myApp, memory: memory)
        let toolNames = ChatViewModel.allowedToolNames(scope: .myApp(myAppId), store: store, toolGateState: ToolGateState())
        return AgentPayload(
            systemPrompt: systemPrompt,
            memory: memory,
            toolFilter: { toolNames.contains($0) }
        )
    }

    // MARK: A2A surface

    /// When invoked A2A expose the full MyApp tool set (notifications
    /// excluded) so the calling agent can read and mutate the canvas.
    public func toolsExposedTo(caller: ChatScope?) -> Set<String>? {
        guard caller != nil else { return nil }
        // Return nil → caller gets whatever payload.toolFilter decides.
        // We leave fine-grained A2A narrowing to a later phase.
        return nil
    }

    // MARK: Private

    @MainActor
    public func buildSystemPrompt(myApp: MyApp?, memory: MemoryStore) -> String {
        guard let myApp else { return "MyApp agent — myApp not found." }
        let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId)
        let typeFragment = type.map {
            ChatViewModel.activeSystemPromptFragment(myApp: myApp, type: $0)
        } ?? ""
        // AGENTS.md layers *over* the type fragment, it no longer replaces it.
        // The type fragment (base + catalog + per-kind, resolved against the
        // current canvas) is dynamic, so a seeded AGENTS.md must not freeze it —
        // otherwise per-kind guidance is lost as components change (issue #164).
        let agentsMd = (try? memory.readFile(path: MemoryStore.pupaAgentsPath))?.content
        var parts: [String] = []
        if !typeFragment.isEmpty {
            parts.append("MyApp type (typeId, myAppName) + per-type rules:\n\n\(typeFragment)")
        }
        if let agentsMd, !agentsMd.isEmpty {
            parts.append("MyApp instructions (pupa/AGENTS.md):\n\n\(agentsMd)")
        }
        return parts.isEmpty ? "MyApp agent." : parts.joined(separator: "\n\n")
    }
}
