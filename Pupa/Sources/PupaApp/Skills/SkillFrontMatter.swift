import Foundation

/// Minimal `---`-delimited frontmatter parser. Deliberately *not* a YAML
/// engine — skills use a small, all-scalar field set (`name`, `description`,
/// `when_to_use`, `argument-hint`, `arguments`, `disable-model-invocation`,
/// `user-invocable`). One `key: value` per line; quotes optional; `#` lines
/// and blanks ignored. Multi-line / list YAML is out of scope.
public enum SkillFrontMatter {

    /// Split `raw` into `(fields, body)`. Keys are lowercased. When there is
    /// no leading `---` fence (or it is never closed) the whole input is the
    /// body and `fields` is empty.
    public static func parse(_ raw: String) -> (fields: [String: String], body: String) {
        let lines = raw.components(separatedBy: "\n")

        // Locate the opening fence: the first non-blank line must be `---`.
        var idx = 0
        while idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
            idx += 1
        }
        guard idx < lines.count,
              lines[idx].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return ([:], raw)
        }

        // Find the closing fence.
        let open = idx
        var close: Int? = nil
        var scan = open + 1
        while scan < lines.count {
            if lines[scan].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                close = scan
                break
            }
            scan += 1
        }
        guard let closeIdx = close else {
            // Unterminated fence → treat the file as plain body.
            return ([:], raw)
        }

        var fields: [String: String] = [:]
        for line in lines[(open + 1)..<closeIdx] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            let value = unquote(String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces))
            fields[key] = value   // last-wins on duplicate keys
        }

        let body = lines[(closeIdx + 1)...]
            .joined(separator: "\n")
            .drop(while: { $0 == "\n" })
        return (fields, String(body))
    }

    /// Parse a comma-separated scalar field into a trimmed, non-empty list.
    /// `nil` when the key is absent (distinct from an empty list). Used for
    /// subagent `tools` / `disabled_tools`.
    public static func list(_ fields: [String: String], _ key: String) -> [String]? {
        guard let raw = fields[key] else { return nil }
        let items = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    /// Parse a `true`/`false` field with a default.
    public static func bool(_ fields: [String: String], _ key: String, default def: Bool) -> Bool {
        guard let raw = fields[key]?.lowercased() else { return def }
        if raw == "true" { return true }
        if raw == "false" { return false }
        return def
    }

    /// Strip a single matched pair of surrounding single/double quotes.
    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last,
              first == last, first == "\"" || first == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }
}
