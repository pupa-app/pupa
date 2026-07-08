import Foundation
import Observation

/// Discovers and caches the skills under a scope's `pupa/skills/` folder.
///
/// One `SkillStore` is bound to one (scope-rooted) `MemoryStore`: a MyApp's
/// memory root, or the orchestrator's. Discovery is a cheap walk of
/// `memory.snapshotPaths()` — only the `pupa/skills/<name>/SKILL.md`
/// entrypoint of each skill folder becomes a `Skill` (supporting files are
/// ignored in v1). The cache is refreshed at `init` and via `rescan()`, which
/// callers invoke when the backing memory mutates.
@MainActor
@Observable
public final class SkillStore {
    private let memory: MemoryStore
    public private(set) var skills: [Skill] = []

    public init(memory: MemoryStore) {
        self.memory = memory
        rescan()
    }

    /// Rebuild the cache from disk. Idempotent and cheap (few small files).
    /// Two roots: the user's `pupa/skills/<name>/SKILL.md` and plugin-bundled
    /// `pupa/plugins/<id>/skills/<name>/SKILL.md`. Names share one flat
    /// namespace; on collision the user skill wins (scanned first).
    public func rescan() {
        var found: [Skill] = []
        var seen: Set<String> = []
        let paths = memory.snapshotPaths()
        for path in paths {
            guard let dir = Self.userSkillName(path) else { continue }
            appendSkill(named: dir, at: path, into: &found, seen: &seen)
        }
        for path in paths {
            guard let dir = Self.pluginSkillName(path) else { continue }
            appendSkill(named: dir, at: path, into: &found, seen: &seen)
        }
        skills = found.sorted { $0.name < $1.name }
    }

    /// `pupa/skills/<name>/SKILL.md` → `<name>` — one folder level, the
    /// entrypoint (supporting files ignored).
    private static func userSkillName(_ path: String) -> String? {
        let prefix = MemoryStore.pupaSkillsDir + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let comps = path.dropFirst(prefix.count)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard comps.count == 2, comps[1] == "SKILL.md", !comps[0].isEmpty else { return nil }
        return String(comps[0])
    }

    /// `pupa/plugins/<id>/skills/<name>/SKILL.md` → `<name>` — one plugin
    /// level, one skill level.
    private static func pluginSkillName(_ path: String) -> String? {
        let prefix = MemoryStore.pupaPluginsDir + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let comps = path.dropFirst(prefix.count)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard comps.count == 4, comps[1] == "skills", comps[3] == "SKILL.md",
              !comps[0].isEmpty, !comps[2].isEmpty else { return nil }
        return String(comps[2])
    }

    private func appendSkill(named dir: String, at path: String, into found: inout [Skill], seen: inout Set<String>) {
        guard !seen.contains(dir), let read = try? memory.readFile(path: path) else { return }
        seen.insert(dir)
        let (fields, body) = SkillFrontMatter.parse(read.content)
        found.append(Skill(
            name: dir,
            displayName: fields["name"],
            description: fields["description"] ?? "",
            whenToUse: fields["when_to_use"],
            argumentHint: fields["argument-hint"],
            arguments: fields["arguments"],
            body: body,
            disableModelInvocation: SkillFrontMatter.bool(fields, "disable-model-invocation", default: false),
            userInvocable: SkillFrontMatter.bool(fields, "user-invocable", default: true),
            sourcePath: path
        ))
    }

    public func skill(named name: String) -> Skill? {
        skills.first { $0.name == name }
    }

    /// Skills offered in the in-chat `/` palette.
    public func paletteSkills() -> [Skill] { skills.filter(\.paletteVisible) }

    /// Skills listed to the model in context (it can load them on demand).
    public func modelContextSkills() -> [Skill] { skills.filter(\.modelVisible) }

    // MARK: - Invocation rendering

    /// Render a skill into the message sent to the agent when the user types
    /// `/<name> <arguments>`: the body with `$ARGUMENTS` / `$0…` substituted,
    /// prefixed by a thin framing line so the model treats it as a playbook.
    public func renderInvocation(_ skill: Skill, arguments: String) -> String {
        "Use the \(skill.name) skill.\n\n\(Self.substitute(skill.body, arguments: arguments))"
    }

    /// Palette-visible skills mapped to `/name` slash commands. `/name args`
    /// shows `/name args` in the chat bubble and sends the rendered skill body
    /// to the agent.
    public func slashCommands() -> [SlashCommand] {
        paletteSkills().map { skill in
            SlashCommand(name: skill.name, summary: skill.summary) { [weak self] args in
                guard let self else { return .appOnly }
                let display = args.isEmpty ? "/\(skill.name)" : "/\(skill.name) \(args)"
                return .rewriteMessage(display: display, payload: self.renderInvocation(skill, arguments: args))
            }
        }
    }

    /// Substitute `$ARGUMENTS` (full string) and `$0`,`$1`… (positional,
    /// shell-style quoting) into `body`. If the body references neither and
    /// `arguments` is non-empty, append an `ARGUMENTS:` line (Claude Code
    /// behaviour). Backslash-escaping of literal `$` is deferred.
    static func substitute(_ body: String, arguments: String) -> String {
        let args = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = tokenize(args)
        let hadArguments = body.contains("$ARGUMENTS")
        var out = body.replacingOccurrences(of: "$ARGUMENTS", with: args)

        var hadPositional = false
        if let re = try? NSRegularExpression(pattern: "\\$([0-9]+)") {
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                hadPositional = true
                let idx = Int(ns.substring(with: match.range(at: 1))) ?? -1
                let replacement = (idx >= 0 && idx < tokens.count) ? tokens[idx] : ""
                out = (out as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }

        if !hadArguments && !hadPositional && !args.isEmpty {
            out += "\n\nARGUMENTS: \(args)"
        }
        return out
    }

    /// Split on whitespace, honouring single/double quoted spans as one token.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inProgress = false
        var quote: Character? = nil
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch); inProgress = true }
            } else if ch == "\"" || ch == "'" {
                quote = ch; inProgress = true
            } else if ch.isWhitespace {
                if inProgress { tokens.append(current); current = ""; inProgress = false }
            } else {
                current.append(ch); inProgress = true
            }
        }
        if inProgress { tokens.append(current) }
        return tokens
    }
}
