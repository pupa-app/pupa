import Foundation

/// Client-side slash commands. Parsed in `ChatViewModel.send(_:)` before any
/// network round trip — slash commands never travel to the backend as plain
/// user text. The three `SlashCommandResult` cases below partition the design
/// space so future commands can declare exactly what should reach the agent
/// and what should appear in the visible transcript.
public enum SlashCommandResult: Equatable {
    /// Pure client-side action. No user bubble, no backend call. Example: `/reset`.
    case appOnly
    /// Replace the user-visible message with `text` before sending to the
    /// backend. The replaced text is what appears in the user bubble. Example:
    /// future `/skill foo` → "use the foo skill: …".
    case rewriteMessage(String)
    /// Send `text` to the backend as context, but do not render a user bubble.
    /// Reserved for future control prompts; not exercised yet.
    case hiddenHint(String)
    /// The input was plain text — fall through to the normal send path.
    case notACommand
    /// Input started with "/" but no registered command matched.
    case unknown(name: String)
}

public struct SlashCommand {
    public let name: String
    public let summary: String
    public let run: () -> SlashCommandResult

    public init(name: String, summary: String, run: @escaping () -> SlashCommandResult) {
        self.name = name
        self.summary = summary
        self.run = run
    }
}

@MainActor
public final class SlashCommandRegistry {
    private let byName: [String: SlashCommand]
    /// Insertion-ordered list of registered commands. Consumed by the in-chat
    /// command palette (live filter as the user types `/…`) and by `/help`.
    public let availableCommands: [SlashCommand]

    public init(commands: [SlashCommand]) {
        var map: [String: SlashCommand] = [:]
        for cmd in commands { map[cmd.name] = cmd }
        self.byName = map
        self.availableCommands = commands
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
    /// command names like `/dump-prompt`.
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
        guard let cmd = byName[name] else { return .unknown(name: name) }
        return cmd.run()
    }
}
