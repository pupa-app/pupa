import Foundation

// MARK: - SubagentPolicy

/// `AgentPolicy` for a generic subagent invocation — a
/// `pupa/agents/<slug>/AGENTS.md` agent run via `invoke_agent`.
///
/// A subagent is always scoped to a specific MiniApp (it inherits the MiniApp's
/// canvas + memory surface) but runs with its persona (the AGENTS.md body)
/// pinned as a context entry and its tool surface narrowed by the
/// frontmatter `tools` / `disabled_tools`.
///
/// This is where the A2A tool-narrowing seam (previously stubbed on
/// `MiniAppPolicy` / `SlackPolicy`) is actually implemented. `runSubagent`
/// uses `narrowedTools` to build the per-turn filter.
public struct SubagentPolicy: AgentPolicy {

    public let miniAppId: UUID
    public let subagent: Subagent

    public init(miniAppId: UUID, subagent: Subagent) {
        self.miniAppId = miniAppId
        self.subagent = subagent
    }

    // MARK: - Tool narrowing

    /// Narrow a MiniApp's resolved tool surface to what this subagent may use:
    /// an optional `tools` allowlist (intersected with what's available),
    /// minus `disabled_tools`, minus the main-chat-only excluded set, always
    /// plus `invoke_agent` (A2A default) unless explicitly disabled.
    public static func narrowedTools(base: Set<String>, subagent: Subagent) -> Set<String> {
        var result = base
        if let allow = subagent.tools {
            result = result.intersection(Set(allow))
        }
        if let disabled = subagent.disabledTools {
            result.subtract(disabled)
        }
        result.subtract(MiniAppType.subagentExcludedToolNames)
        // A2A on by default: a subagent can invoke siblings unless it disabled it.
        if subagent.disabledTools?.contains("invoke_agent") != true {
            result.formUnion(MiniAppType.subagentToolNames)
        }
        return result
    }

    // MARK: - AgentPolicy

    @MainActor
    public func payload(for scope: ChatScope, store: MiniAppStore) async -> AgentPayload {
        let miniApp = store.miniApps.first(where: { $0.id == miniAppId })
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(miniAppId: miniAppId))
        let base = ChatViewModel.allowedToolNames(
            scope: .miniApp(miniAppId), store: store, toolGateState: ToolGateState()
        )
        let narrowed = Self.narrowedTools(base: base, subagent: subagent)
        // Base system prompt = the MiniApp's, plus the subagent's persona body.
        let miniAppPrompt = MiniAppPolicy(miniAppId: miniAppId).buildSystemPrompt(miniApp: miniApp, memory: memory)
        let persona = subagent.body.isEmpty ? "" : "\n\n## Subagent persona (\(subagent.displayName ?? subagent.name))\n\(subagent.body)"
        return AgentPayload(
            systemPrompt: miniAppPrompt + persona,
            memory: memory,
            toolFilter: { narrowed.contains($0) }
        )
    }

    // MARK: - A2A surface

    public func toolsExposedTo(caller: ChatScope?) -> Set<String>? {
        guard caller != nil else { return nil }
        // Fine-grained A2A narrowing is resolved from the subagent frontmatter
        // at invocation time (see `narrowedTools`); callers get that set.
        return nil
    }

    /// A2A is on by default; chain depth is bounded by `AgentInvocationGate`.
    public func canInvoke(from callerScope: ChatScope?) -> Bool { true }
}
