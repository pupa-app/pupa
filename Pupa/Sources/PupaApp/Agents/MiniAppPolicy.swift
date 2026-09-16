import Foundation

// MARK: - MiniAppPolicy

/// `AgentPolicy` for an active MiniApp (`.miniApp(id)` scope).
///
/// Memory root:  `<sandbox>/miniapps/<name>/`
/// System prompt: `<root>/pupa/AGENTS.md` (or type-fragment fallback).
/// Tools: type's resolved tool names + HITL + tool-gated memory /
///        notifications / per-kind tools. Never orchestrator tools.
public struct MiniAppPolicy: AgentPolicy {

    public let miniAppId: UUID

    public init(miniAppId: UUID) {
        self.miniAppId = miniAppId
    }

    // MARK: AgentPolicy

    @MainActor
    public func payload(for scope: ChatScope, store: MiniAppStore) async -> AgentPayload {
        let miniApp = store.miniApps.first(where: { $0.id == miniAppId })
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(miniAppId: miniAppId))
        let systemPrompt = buildSystemPrompt(miniApp: miniApp, memory: memory)
        let toolNames = ChatViewModel.allowedToolNames(scope: .miniApp(miniAppId), store: store, toolGateState: ToolGateState())
        return AgentPayload(
            systemPrompt: systemPrompt,
            memory: memory,
            toolFilter: { toolNames.contains($0) }
        )
    }

    // MARK: A2A surface

    /// When invoked A2A expose the full MiniApp tool set (notifications
    /// excluded) so the calling agent can read and mutate the canvas.
    public func toolsExposedTo(caller: ChatScope?) -> Set<String>? {
        guard caller != nil else { return nil }
        // Return nil → caller gets whatever payload.toolFilter decides.
        // We leave fine-grained A2A narrowing to a later phase.
        return nil
    }

    // MARK: Private

    @MainActor
    public func buildSystemPrompt(miniApp: MiniApp?, memory: MemoryStore) -> String {
        guard let miniApp else { return "MiniApp agent — miniApp not found." }
        let type = MiniAppTypeRegistry.shared.resolve(id: miniApp.typeId)
        let typeFragment = type.map {
            ChatViewModel.activeSystemPromptFragment(miniApp: miniApp, type: $0)
        } ?? ""
        // AGENTS.md layers *over* the type fragment, it no longer replaces it.
        // The type fragment (base + catalog + per-kind, resolved against the
        // current canvas) is dynamic, so a seeded AGENTS.md must not freeze it —
        // otherwise per-kind guidance is lost as components change (issue #164).
        let agentsMd = (try? memory.readFile(path: MemoryStore.pupaAgentsPath))?.content
        var parts: [String] = []
        if !typeFragment.isEmpty {
            parts.append("MiniApp type (typeId, miniAppName) + per-type rules:\n\n\(typeFragment)")
        }
        if let agentsMd, !agentsMd.isEmpty {
            parts.append("MiniApp instructions (pupa/AGENTS.md):\n\n\(agentsMd)")
        }
        return parts.isEmpty ? "MiniApp agent." : parts.joined(separator: "\n\n")
    }
}
