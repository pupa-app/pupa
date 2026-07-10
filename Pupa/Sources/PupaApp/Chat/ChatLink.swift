import Foundation

/// In-app deep links the agent embeds in chat (and notes) as
/// `[title](pupa://…)`. Tapping one routes the canvas to a
/// `SidebarSelection` instead of opening the system browser. Mirrors the
/// `pupa-mention://` interception `SlackView` already does for DMs.
///
/// **Scope-relative by design.** The agent only ever sees note paths
/// *relative to its own memory root* (the myApp's store is rooted at
/// `appRoot(myAppName:)`), so it emits `pupa://memory/<that-same-path>`
/// — no app id, no global-root knowledge. The resolver binds the path to
/// the chat's current scope: a myApp chat → `.myAppMemoryFile`, the
/// orchestrator → `.memoryFile`. The explicit `myapp/<uuid>/memory/…`
/// form exists only for cross-scope links (e.g. the orchestrator pointing
/// into one app); the per-app agent never needs it.
public enum ChatLink {
    /// URL scheme reserved for in-app navigation. Distinct from
    /// `pupa-mention` (Slack DMs) and the `com.pupa-app.app-bundle` file type.
    public static let scheme = "pupa"

    /// Resolve a `pupa://` URL to a navigation target, or `nil` if it isn't
    /// one (callers fall through to `.systemAction`). `currentMyAppId` is the
    /// myApp owning the chat the link was tapped in — `nil` in orchestrator
    /// scope — used to bind scope-relative `memory` / `component` links.
    ///
    /// Forms:
    /// - `pupa://memory/<path>` — scope-relative note
    /// - `pupa://myapp/<uuid>/memory/<path>` — explicit cross-scope note
    /// - `pupa://component/<componentId>` — component in the current myApp
    public static func sidebarSelection(
        from url: URL,
        currentMyAppId: UUID?
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
            return currentMyAppId.map { .myAppMemoryFile($0, path) } ?? .memoryFile(path)

        case "myapp":
            // myapp/<uuid>/memory/<path…>
            guard segments.count >= 3, segments[1] == "memory",
                  let id = UUID(uuidString: segments[0]) else { return nil }
            return .myAppMemoryFile(id, segments.dropFirst(2).joined(separator: "/"))

        case "component":
            guard let id = currentMyAppId,
                  let componentId = segments.first, !componentId.isEmpty else { return nil }
            return .myAppComponent(id, componentId)

        default:
            return nil
        }
    }
}
