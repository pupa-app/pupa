import Foundation

// MARK: - SubagentPolicy

/// `AgentPolicy` for a generic subagent invocation — a
/// `pupa/agents/<slug>/AGENTS.md` agent run via `invoke_agent`.
///
/// A subagent is always scoped to a specific MyApp (it inherits the MyApp's
/// canvas + memory surface) but runs with its persona (the AGENTS.md body)
/// pinned as a context entry and its tool surface narrowed by the
/// frontmatter `tools` / `disabled_tools`.
///
/// This is where the A2A tool-narrowing seam (previously stubbed on
/// `MyAppPolicy` / `SlackPolicy`) is actually implemented. `runSubagent`
/// uses `narrowedTools` to build the per-turn filter.
public struct SubagentPolicy: AgentPolicy {

    public let myAppId: UUID
    public let subagent: Subagent

    public init(myAppId: UUID, subagent: Subagent) {
        self.myAppId = myAppId
        self.subagent = subagent
    }

    // MARK: - Tool narrowing

    /// Narrow a MyApp's resolved tool surface to what this subagent may use:
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
        result.subtract(MyAppType.subagentExcludedToolNames)
        // A2A on by default: a subagent can invoke siblings unless it disabled it.
        if subagent.disabledTools?.contains("invoke_agent") != true {
            result.formUnion(MyAppType.subagentToolNames)
        }
        return result
    }

    // MARK: - AgentPolicy

    @MainActor
    public func payload(for scope: ChatScope, store: MyAppStore) async -> AgentPayload {
        let myApp = store.myApps.first(where: { $0.id == myAppId })
        let name = myApp?.name ?? ""
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: name))
        let base = ChatViewModel.allowedToolNames(
            scope: .myApp(myAppId), store: store, toolGateState: ToolGateState()
        )
        let narrowed = Self.narrowedTools(base: base, subagent: subagent)
        // Base system prompt = the MyApp's, plus the subagent's persona body.
        let myAppPrompt = MyAppPolicy(myAppId: myAppId).buildSystemPrompt(myApp: myApp, memory: memory)
        let persona = subagent.body.isEmpty ? "" : "\n\n## Subagent persona (\(subagent.displayName ?? subagent.name))\n\(subagent.body)"
        return AgentPayload(
            systemPrompt: myAppPrompt + persona,
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
