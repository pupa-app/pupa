import Foundation

/// In-app deep links the agent embeds in chat (and notes) as
/// `[title](pupa://…)`. Tapping one routes the canvas to a
/// `SidebarSelection` instead of opening the system browser. Mirrors the
/// `pupa-mention://` interception `SlackView` already does for DMs.
///
/// **Scope-relative by design.** The agent only ever sees note paths
/// *relative to its own memory root* (the miniApp's store is rooted at
/// `appRoot(miniAppId:)`), so it emits `pupa://memory/<that-same-path>`
/// — no app id, no global-root knowledge. The resolver binds the path to
/// the chat's current scope: a miniApp chat → `.miniAppMemoryFile`, the
/// orchestrator → `.memoryFile`. The explicit `miniapp/<uuid>/memory/…`
/// form exists only for cross-scope links (e.g. the orchestrator pointing
/// into one app); the per-app agent never needs it.
public enum ChatLink {
    /// URL scheme reserved for in-app navigation. Distinct from
    /// `pupa-mention` (Slack DMs) and the `com.pupa-app.app-bundle` file type.
    public static let scheme = "pupa"

    /// Resolve a `pupa://` URL to a navigation target, or `nil` if it isn't
    /// one (callers fall through to `.systemAction`). `currentMiniAppId` is the
    /// miniApp owning the chat the link was tapped in — `nil` in orchestrator
    /// scope — used to bind scope-relative `memory` / `component` links.
    ///
    /// Forms:
    /// - `pupa://memory/<path>` — scope-relative note
    /// - `pupa://miniapp/<uuid>/memory/<path>` — explicit cross-scope note
    /// - `pupa://component/<componentId>` — component in the current miniApp
    public static func sidebarSelection(
        from url: URL,
        currentMiniAppId: UUID?
    ) -> SidebarSelection? {
        guard url.scheme == scheme,
              let host = url.host(percentEncoded: false) else { return nil }
        let segments = url.path(percentEncoded: false)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        switch host {
        case "memory":
            let path = segments.joined(separator: "/")
            guard !path.isEmpty else { return nil }
            return currentMiniAppId.map { .miniAppMemoryFile($0, path) } ?? .memoryFile(path)

        case "miniapp", "myapp":
            // miniapp/<uuid>/memory/<path…>
            guard segments.count >= 3, segments[1] == "memory",
                  let id = UUID(uuidString: segments[0]) else { return nil }
            return .miniAppMemoryFile(id, segments.dropFirst(2).joined(separator: "/"))

        case "component":
            guard let id = currentMiniAppId,
                  let componentId = segments.first, !componentId.isEmpty else { return nil }
            return .miniAppComponent(id, componentId)

        default:
            return nil
        }
    }

    /// Human label for a `pupa://` URL shown where no markdown link title
    /// exists — tracker `.link` field pills, which carry a bare URL string.
    /// `nil` for anything unlabelable (web URLs, malformed forms) so callers
    /// keep their own fallback (host for web links).
    ///
    /// Notes label with the file name sans extension; without this every
    /// note pill reads "memory", the URL's host.
    public static func displayLabel(for url: URL) -> String? {
        guard url.scheme == scheme,
              let host = url.host(percentEncoded: false) else { return nil }
        let segments = url.path(percentEncoded: false)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        switch host {
        case "memory":
            return segments.last.map(noteName)

        case "miniapp", "myapp":
            guard segments.count >= 3, segments[1] == "memory",
                  UUID(uuidString: segments[0]) != nil else { return nil }
            return segments.last.map(noteName)

        case "component":
            return segments.first.flatMap { $0.isEmpty ? nil : $0 }

        default:
            return nil
        }
    }

    /// File name minus its extension, keeping inner dots (`v1.2.notes.md` →
    /// `v1.2.notes`). Extensionless names pass through whole.
    private static func noteName(_ fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.isEmpty ? fileName : stem
    }
}
