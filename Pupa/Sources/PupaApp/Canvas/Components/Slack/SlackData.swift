import Foundation

// Slack component data model. Moved out of CanvasState (issue #162).
// The `CanvasApp.slack` enum arm + its Codable stay in CanvasState.

// MARK: - Slack component

// Slack agents are generic filesystem subagents — `pupa/agents/<slug>/AGENTS.md`
// discovered by `AgentStore`. A Slack component's workspace roster is *all*
// subagents in the MyApp; the component holds no agent list of its own.
// Channels reference agents by their subagent slug.

/// How a Slack channel is presented in the sidebar and which members
/// can post. `channel` is an open public room; `groupDM` is a fixed
/// roster of 3+ members; `dm` is a fixed pair (one user + one agent,
/// or two agents).
public enum SlackChannelType: String, Codable, Hashable, Sendable {
    case channel
    case groupDM
    case dm
}

/// One room in a Slack component. `memberAgentIds` is the assigned
/// roster (agents that can post + are auto-eligible to be `@`-mentioned);
/// `subscriberAgentIds` is informational only in v1 (used by the
/// sidebar to show "subscribed channels" per agent).
public struct SlackChannel: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var type: SlackChannelType
    public var memberAgentIds: [String]
    public var subscriberAgentIds: [String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        type: SlackChannelType,
        memberAgentIds: [String] = [],
        subscriberAgentIds: [String] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.memberAgentIds = memberAgentIds
        self.subscriberAgentIds = subscriberAgentIds
    }
}

/// Who authored a `SlackMessage`. `user` is the human typing in the
/// composer; `agent` is any `SlackAgent` posting via `slackPostMessage`.
public enum SlackAuthorKind: String, Codable, Hashable, Sendable {
    case user
    case agent
}

/// One message in a Slack channel. `authorId` is the user identifier
/// ("user" for the human; an agent's stable id for agents).
/// `mentionedAgentIds` is the parsed `@`-mention list — for user
/// messages it drives which agents the composer invokes; for agent
/// messages it's informational (rendered as pills in the view).
public struct SlackMessage: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let channelId: String
    public var authorKind: SlackAuthorKind
    public var authorId: String
    public var text: String
    public var timestamp: Date
    public var mentionedAgentIds: [String]

    public init(
        id: String = UUID().uuidString,
        channelId: String,
        authorKind: SlackAuthorKind,
        authorId: String,
        text: String,
        timestamp: Date = Date(),
        mentionedAgentIds: [String] = []
    ) {
        self.id = id
        self.channelId = channelId
        self.authorKind = authorKind
        self.authorId = authorId
        self.text = text
        self.timestamp = timestamp
        self.mentionedAgentIds = mentionedAgentIds
    }
}

/// Body of a Slack canvas component — the full state of the
/// multi-agent room: every agent, every channel, the message history
/// per channel, and which channel the user is currently viewing.
/// Persists as part of the enclosing `CanvasApp` via `MyAppStore`'s
/// UserDefaults blob.
public struct SlackData: Codable, Hashable, Sendable {
    public var channels: [SlackChannel]
    public var messagesByChannel: [String: [SlackMessage]]
    public var activeChannelId: String?

    public init(
        channels: [SlackChannel] = [],
        messagesByChannel: [String: [SlackMessage]] = [:],
        activeChannelId: String? = nil
    ) {
        self.channels = channels
        self.messagesByChannel = messagesByChannel
        self.activeChannelId = activeChannelId
    }

    enum CodingKeys: String, CodingKey {
        case channels, messagesByChannel, activeChannelId
    }

    /// Backward-compatible decoder — every field defaults so a
    /// pre-Slack on-disk blob or a freshly-seeded empty body decodes
    /// cleanly. A legacy `agents` key (pre-subagent) is simply ignored;
    /// agents now live at `pupa/agents/<slug>/AGENTS.md`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.channels = try c.decodeIfPresent([SlackChannel].self, forKey: .channels) ?? []
        self.messagesByChannel = try c.decodeIfPresent([String: [SlackMessage]].self, forKey: .messagesByChannel) ?? [:]
        self.activeChannelId = try c.decodeIfPresent(String.self, forKey: .activeChannelId)
    }
}
