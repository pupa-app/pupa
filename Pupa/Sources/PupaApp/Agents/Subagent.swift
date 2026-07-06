import Foundation

/// A Claude-Code-style subagent: a `pupa/agents/<slug>/AGENTS.md` markdown
/// file with YAML-ish frontmatter. The directory name is the slug (the token
/// `invoke_agent` targets and the stable `id`); the folder doubles as the
/// subagent's private memory subtree. The frontmatter `name` is a display
/// label only.
///
/// Discovered from disk by `AgentStore` — drop the file and the subagent
/// exists. Invoked via the `invoke_agent` frontend tool, which spins a
/// transient sub-session scoped to the parent MyApp (see
/// `ChatSessionCoordinator.runSubagent`).
public struct Subagent: Sendable, Hashable, Identifiable {
    /// Directory name (slugified). The `invoke_agent` target and `id`.
    public let name: String
    /// Frontmatter `name` — display label only. `nil` → fall back to `name`.
    public let displayName: String?
    /// What the subagent does. Surfaced to the model for delegation choice.
    public let description: String
    /// Extra "when to delegate to me" hint appended to `description`.
    public let whenToUse: String?
    /// Frontmatter `tools` — allowlist of tool names this subagent may use.
    /// `nil` → inherit the parent MyApp's full surface (minus `disabledTools`).
    public let tools: [String]?
    /// Frontmatter `disabled_tools` — tool names to strip from the surface.
    public let disabledTools: [String]?
    /// Per-agent LLM model id (frontmatter `model`). Paired with `provider`;
    /// both must be non-nil for the override to apply, else inherit the MyApp's.
    public let model: String?
    /// Per-agent LLM provider (frontmatter `provider`). See `model`.
    public let provider: String?
    /// Markdown body after the frontmatter — the persona / system prompt.
    public let body: String
    /// Root-relative source path, e.g. `pupa/agents/researcher/AGENTS.md`.
    public let sourcePath: String

    public init(
        name: String,
        displayName: String? = nil,
        description: String = "",
        whenToUse: String? = nil,
        tools: [String]? = nil,
        disabledTools: [String]? = nil,
        model: String? = nil,
        provider: String? = nil,
        body: String = "",
        sourcePath: String
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.whenToUse = whenToUse
        self.tools = tools
        self.disabledTools = disabledTools
        self.model = model
        self.provider = provider
        self.body = body
        self.sourcePath = sourcePath
    }

    public var id: String { name }

    /// Per-agent LLM selection, or `nil` to inherit. Both `provider` and
    /// `model` must be present.
    public var llmSelection: (provider: String, model: String)? {
        guard let provider, let model else { return nil }
        return (provider, model)
    }

    /// One-line summary. Prefers `description`, falls back to `whenToUse`.
    public var summary: String {
        if !description.isEmpty { return description }
        if let whenToUse, !whenToUse.isEmpty { return whenToUse }
        return "Subagent"
    }
}
