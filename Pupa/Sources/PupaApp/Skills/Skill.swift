import Foundation

/// A Claude-Code-style skill: a `pupa/skills/<name>/SKILL.md` markdown file
/// with YAML-ish frontmatter. The directory name is the `/command` token and
/// the stable `id`; the frontmatter `name` is a display label only.
///
/// Behaviour matrix (mirrors Claude Code):
/// - default → user `/name` and the model can invoke; description in context.
/// - `disable-model-invocation: true` → only `/name`; description not in context.
/// - `user-invocable: false` → hidden from the `/` palette; model-only.
public struct Skill: Sendable, Hashable, Identifiable {
    /// Directory name (slugified). The `/command` token and `id`.
    public let name: String
    /// Frontmatter `name` — display label only. `nil` → fall back to `name`.
    public let displayName: String?
    /// What the skill does + when to use it. Surfaced to the model.
    public let description: String
    /// Extra trigger context appended to `description` in the listing.
    public let whenToUse: String?
    /// Autocomplete hint, e.g. `[issue-number]`.
    public let argumentHint: String?
    /// Raw `arguments` frontmatter (named positional args). Stored, not yet
    /// used for `$name` substitution in v1 (positional `$0…` + `$ARGUMENTS`).
    public let arguments: String?
    /// Markdown body after the frontmatter — the playbook the agent follows.
    public let body: String
    /// `true` → the model cannot auto-load this; only the user `/name` can.
    public let disableModelInvocation: Bool
    /// `false` → hidden from the `/` palette (model-only background knowledge).
    public let userInvocable: Bool
    /// Root-relative source path, e.g. `pupa/skills/deploy/SKILL.md`.
    public let sourcePath: String

    public init(
        name: String,
        displayName: String? = nil,
        description: String = "",
        whenToUse: String? = nil,
        argumentHint: String? = nil,
        arguments: String? = nil,
        body: String = "",
        disableModelInvocation: Bool = false,
        userInvocable: Bool = true,
        sourcePath: String
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.whenToUse = whenToUse
        self.argumentHint = argumentHint
        self.arguments = arguments
        self.body = body
        self.disableModelInvocation = disableModelInvocation
        self.userInvocable = userInvocable
        self.sourcePath = sourcePath
    }

    public var id: String { name }

    /// Listed to the model in context (so it knows the skill exists).
    public var modelVisible: Bool { !disableModelInvocation }

    /// Offered in the in-chat `/` command palette.
    public var paletteVisible: Bool { userInvocable }

    /// One-line summary for the palette / `/help`. Prefers `description`,
    /// falls back to `whenToUse`, then a generic label.
    public var summary: String {
        if !description.isEmpty { return description }
        if let whenToUse, !whenToUse.isEmpty { return whenToUse }
        return "Skill"
    }
}
