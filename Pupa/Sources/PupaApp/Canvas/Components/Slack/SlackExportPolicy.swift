import Foundation

/// Slack: keep channels (the reusable workspace); drop the chat transcript.
/// Agent personas travel separately as `pupa/agents/<slug>/AGENTS.md` files in
/// the app memory tree — they are not part of `SlackData`.
public struct SlackExportPolicy: ComponentExportPolicy {
    public init() {}
    public let kind = "slack"
    public func strippingUserData(_ body: CanvasApp) -> CanvasApp {
        guard case .slack(var s) = body else { return body }
        s.messagesByChannel = [:]
        s.activeChannelId = nil
        return .slack(s)
    }
    public var exportDataWarning: String? {
        "Slack keeps channels; agent personas travel as pupa/agents/ files. Chat messages are removed when records are excluded."
    }
}
