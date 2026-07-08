import Foundation
import Observation

/// Discovers and caches the subagents under a scope's `pupa/agents/` folder.
///
/// One `AgentStore` is bound to one (scope-rooted) `MemoryStore` — a MyApp's
/// memory root. Discovery is a cheap walk of `memory.snapshotPaths()`: only
/// the `pupa/agents/<slug>/AGENTS.md` entrypoint of each subagent folder
/// becomes a `Subagent` (supporting files — the agent's private notes — are
/// ignored). The cache refreshes at `init` and via `rescan()`, which the
/// coordinator invokes when the backing memory mutates.
///
/// Mirrors `SkillStore` exactly; the two are the read-side halves of the
/// `pupa/` config folder (`pupa/skills/` and `pupa/agents/`).
@MainActor
@Observable
public final class AgentStore {
    private let memory: MemoryStore
    public private(set) var agents: [Subagent] = []

    public init(memory: MemoryStore) {
        self.memory = memory
        rescan()
    }

    /// Rebuild the cache from disk. Idempotent and cheap (few small files).
    public func rescan() {
        let prefix = MemoryStore.pupaAgentsDir + "/"   // "pupa/agents/"
        var found: [Subagent] = []
        var seen: Set<String> = []
        for path in memory.snapshotPaths() {
            guard path.hasPrefix(prefix) else { continue }
            // Expect exactly `<dir>/AGENTS.md` — one folder level, the entrypoint.
            let rest = path.dropFirst(prefix.count)
            let comps = rest.split(separator: "/", omittingEmptySubsequences: false)
            guard comps.count == 2, comps[1] == "AGENTS.md" else { continue }
            let dir = String(comps[0])
            guard !dir.isEmpty, !seen.contains(dir) else { continue }
            guard let read = try? memory.readFile(path: path) else { continue }
            seen.insert(dir)
            let (fields, body) = SkillFrontMatter.parse(read.content)
            found.append(Subagent(
                name: dir,
                displayName: fields["name"],
                description: fields["description"] ?? "",
                whenToUse: fields["when_to_use"],
                tools: SkillFrontMatter.list(fields, "tools"),
                disabledTools: SkillFrontMatter.list(fields, "disabled_tools"),
                model: fields["model"],
                provider: fields["provider"],
                body: body,
                sourcePath: path
            ))
        }
        agents = found.sorted { $0.name < $1.name }
    }

    public func agent(named name: String) -> Subagent? {
        let slug = MemoryStore.slugify(name)
        return agents.first { $0.name == slug || $0.name == name }
    }

    /// Subagents listed to the model in context (it can invoke any on demand).
    /// Everything discovered is model-visible in v1 — no hidden subagents yet.
    public func modelContextAgents() -> [Subagent] { agents }

    // MARK: - Canonical writer

    /// Create (or overwrite) a subagent by writing its
    /// `pupa/agents/<slug>/AGENTS.md`, then rescanning so it exists
    /// immediately. The single programmatic entrypoint used by the Slack
    /// component's create-agent UI (and any future `create_agent` tool). The
    /// slug is derived from `name`; the frontmatter `name` keeps the display
    /// label. Returns the slug on success.
    @discardableResult
    public func createAgent(
        name: String,
        description: String = "",
        prompt: String = "",
        whenToUse: String? = nil,
        tools: [String]? = nil,
        disabledTools: [String]? = nil,
        model: String? = nil,
        provider: String? = nil
    ) throws -> String {
        let slug = MemoryStore.slugify(name)
        guard !slug.isEmpty else { throw MemoryError.invalidPath(name) }
        let path = "\(MemoryStore.pupaAgentsDir)/\(slug)/AGENTS.md"
        let content = Self.renderAgentFile(
            name: name,
            description: description,
            whenToUse: whenToUse,
            tools: tools,
            disabledTools: disabledTools,
            model: model,
            provider: provider,
            body: prompt
        )
        _ = try memory.writeFile(path: path, content: content)
        rescan()
        return slug
    }

    /// Overwrite a subagent's per-agent LLM override, preserving every other
    /// frontmatter field + the persona body. `provider`/`model` both nil (or
    /// empty) clears the override. Returns false if no such subagent.
    @discardableResult
    public func setModel(slug: String, provider: String?, model: String?) throws -> Bool {
        try rewrite(slug: slug) { a in
            Self.renderAgentFile(
                name: a.displayName ?? a.name, description: a.description,
                whenToUse: a.whenToUse, tools: a.tools, disabledTools: a.disabledTools,
                model: (model?.isEmpty == false) ? model : nil,
                provider: (provider?.isEmpty == false) ? provider : nil,
                body: a.body
            )
        }
    }

    /// Overwrite a subagent's `disabled_tools`, preserving every other
    /// frontmatter field + the persona body. Empty set clears it.
    @discardableResult
    public func setDisabledTools(slug: String, _ names: Set<String>) throws -> Bool {
        try rewrite(slug: slug) { a in
            Self.renderAgentFile(
                name: a.displayName ?? a.name, description: a.description,
                whenToUse: a.whenToUse, tools: a.tools,
                disabledTools: names.isEmpty ? nil : names.sorted(),
                model: a.model, provider: a.provider, body: a.body
            )
        }
    }

    /// Load the subagent, re-render its file via `render`, write it back to
    /// its existing slug folder (never re-derived from the display name), and
    /// rescan.
    @discardableResult
    private func rewrite(slug: String, _ render: (Subagent) -> String) throws -> Bool {
        guard let a = agent(named: slug) else { return false }
        _ = try memory.writeFile(
            path: "\(MemoryStore.pupaAgentsDir)/\(a.name)/AGENTS.md",
            content: render(a)
        )
        rescan()
        return true
    }

    /// Render a subagent's `AGENTS.md`: frontmatter + persona body. Scalar
    /// fields only (matches `SkillFrontMatter`'s reader); list fields are
    /// comma-joined.
    static func renderAgentFile(
        name: String,
        description: String,
        whenToUse: String?,
        tools: [String]?,
        disabledTools: [String]?,
        model: String?,
        provider: String?,
        body: String
    ) -> String {
        var lines: [String] = ["---", "name: \(name)"]
        if !description.isEmpty { lines.append("description: \(description)") }
        if let whenToUse, !whenToUse.isEmpty { lines.append("when_to_use: \(whenToUse)") }
        if let tools, !tools.isEmpty { lines.append("tools: \(tools.joined(separator: ", "))") }
        if let disabledTools, !disabledTools.isEmpty {
            lines.append("disabled_tools: \(disabledTools.joined(separator: ", "))")
        }
        if let model, !model.isEmpty { lines.append("model: \(model)") }
        if let provider, !provider.isEmpty { lines.append("provider: \(provider)") }
        lines.append("---")
        lines.append("")
        lines.append(body.isEmpty ? "_No persona set._" : body)
        return lines.joined(separator: "\n") + "\n"
    }
}
