import Foundation

/// Client-side slash commands. Parsed in `ChatViewModel.send(_:)` before any
/// network round trip — slash commands never travel to the backend as plain
/// user text. The cases below partition the design space so commands can
/// declare exactly what should reach the agent and what should appear in the
/// visible transcript.
public enum SlashCommandResult: Equatable {
    /// Pure client-side action. No user bubble, no backend call. Example: `/help`.
    case appOnly
    /// Send `payload` to the backend as the user turn, but render `display` in
    /// the user bubble instead. Lets `/skill foo bar` show `/skill foo bar`
    /// while the agent receives the skill's full rendered instructions.
    case rewriteMessage(display: String, payload: String)
    /// Send `payload` to the backend as context, but do not render a user
    /// bubble. Reserved for future control prompts; not exercised yet.
    case hiddenHint(String)
    /// The input was plain text — fall through to the normal send path.
    case notACommand
    /// Input started with "/" but no registered command matched.
    case unknown(name: String)
}

public struct SlashCommand {
    public let name: String
    public let summary: String
    /// `arguments` is the trimmed text after the command token (e.g. for
    /// `/skill foo bar` it is `"foo bar"`). Built-ins that take no arguments
    /// ignore it.
    public let run: (_ arguments: String) -> SlashCommandResult

    public init(name: String, summary: String, run: @escaping (_ arguments: String) -> SlashCommandResult) {
        self.name = name
        self.summary = summary
        self.run = run
    }
}

@MainActor
public final class SlashCommandRegistry {
    private let byName: [String: SlashCommand]
    /// Built-in commands, in insertion order.
    public let builtins: [SlashCommand]
    /// Live source of skill-backed commands (discovered from `pupa/skills/`).
    /// Consulted on every `filter` / `dispatch` so newly written skills appear
    /// without rebuilding the registry. Built-ins win on name collision.
    private let skillProvider: () -> [SlashCommand]

    public init(
        commands: [SlashCommand],
        skillProvider: @escaping () -> [SlashCommand] = { [] }
    ) {
        var map: [String: SlashCommand] = [:]
        for cmd in commands { map[cmd.name] = cmd }
        self.byName = map
        self.builtins = commands
        self.skillProvider = skillProvider
    }

    /// Built-ins followed by skill commands, with skills that collide with a
    /// built-in name dropped (so `/help` can never be shadowed). Drives the
    /// in-chat palette and `/help`.
    public var availableCommands: [SlashCommand] {
        let builtinNames = Set(builtins.map(\.name))
        return builtins + skillProvider().filter { !builtinNames.contains($0.name) }
    }

    /// Commands whose `name` starts with `query` (case-insensitive). `query`
    /// is the substring AFTER the leading slash. Empty query → all commands.
    public func filter(prefix query: String) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return availableCommands }
        return availableCommands.filter { $0.name.lowercased().hasPrefix(q) }
    }

    /// Parse `raw` (already trimmed by the caller) and dispatch.
    /// Only treats the input as a command when it matches
    /// `^/[A-Za-z_][A-Za-z0-9_-]*(\s.*)?$` — this keeps mid-text slashes like
    /// `path/to/file` from being misread while still accepting hyphenated
    /// command names like `/dump-prompt`. The text after the command token is
    /// passed to the command as `arguments`.
    public func dispatch(_ raw: String) -> SlashCommandResult {
        guard raw.first == "/" else { return .notACommand }
        let rest = raw.dropFirst()
        guard let firstChar = rest.first, firstChar.isLetter || firstChar == "_" else {
            return .notACommand
        }
        let head = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let after = rest.dropFirst(head.count)
        if let next = after.first, !next.isWhitespace {
            // e.g. "/foo!" or "/foo." — not a clean command token; treat as plain text.
            return .notACommand
        }
        let name = String(head)
        let arguments = String(after).trimmingCharacters(in: .whitespacesAndNewlines)
        if let cmd = byName[name] { return cmd.run(arguments) }
        // Built-ins win; only consult skills when no built-in matched.
        if let skill = skillProvider().first(where: { $0.name == name }) {
            return skill.run(arguments)
        }
        return .unknown(name: name)
    }
}
