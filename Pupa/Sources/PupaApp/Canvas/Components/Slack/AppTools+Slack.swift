import Foundation
import AGUIKit

extension AppTools {
    // MARK: - Slack tools

    /// Tools that drive a Slack canvas component. Three flavours:
    ///
    /// - **Discovery** (any caller): `slackListAgents`,
    ///   `slackListChannels`, `slackReadChannelHistory`.
    /// - **Posting** (sub-agents only): `slackPostMessage`.
    ///   Authors a message as the current sub-agent and fans out
    ///   to any `@mentioned` agents through the same
    ///   `invokeSlackAgent` path the user composer uses — so the
    ///   `SlackInvoker` reentrancy + max-depth guard applies to
    ///   agent-triggered chains too. Multiple calls in one turn
    ///   are allowed; auto-post of the agent's final assistant
    ///   text is suppressed when this tool has been used.
    /// - **Admin** (main chat panel only): `slackCreateAgent`,
    ///   `slackCreateChannels`, `slackAddAgentsToChannel`. Refuse
    ///   when `context.currentAgentId` is non-nil so sub-agents
    ///   can't spawn more agents / channels in v1.
    @MainActor
    public static func registerSlackTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID,
        memory: MemoryStore? = nil,
        context: SlackToolContext
    ) {
        // --- Discovery -----------------------------------------

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackListAgents",
                description: """
                List every subagent available in this MyApp (the `pupa/agents/` \
                roster) — these are the agents a channel can add and users can \
                @-mention. Result echoes {agents: [{id, name, description}]}, \
                where `id` is the slug used in channel rosters and @-mentions.
                """,
                parameters: ["type": "object", "properties": [:]]
            ),
            handler: { _ in
                return await MainActor.run {
                    let roster = memory.map { AgentStore(memory: $0).agents } ?? []
                    let entries: [AnyJSON] = roster.map { a in
                        .object([
                            "id": .string(a.name),
                            "name": .string(a.displayName ?? a.name),
                            "description": .string(a.description),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "agents": .array(entries),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackListChannels",
                description: """
                List every channel / group-DM / DM in this MyApp's \
                Slack canvas. Result echoes \
                {channels: [{id, name, type, memberAgentIds}]}.
                """,
                parameters: ["type": "object", "properties": [:]]
            ),
            handler: { _ in
                return await MainActor.run {
                    guard let s = slackData(store, myAppId: myAppId) else {
                        return .object(["ok": .bool(false), "error": "no slack component"])
                    }
                    let entries: [AnyJSON] = s.channels.map { c in
                        .object([
                            "id": .string(c.id),
                            "name": .string(c.name),
                            "type": .string(c.type.rawValue),
                            "memberAgentIds": .array(c.memberAgentIds.map { .string($0) }),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "channels": .array(entries),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackReadChannelHistory",
                description: """
                Read messages from a Slack channel. `channelId` is \
                required; `limit` (optional, default 50) caps the \
                number of messages returned. By default returns the \
                most-recent messages. Pass `before` (a message id) \
                to fetch the page strictly older than that message — \
                use the `id` of the oldest message from a previous \
                call to walk back through history. Invocation prompts \
                only include the most recent slice of a channel, so \
                use this tool when older context matters. Result \
                echoes {messages: [{id, channelId, authorKind, \
                authorId, text, timestamp}], totalMessages, hasMore}; \
                `hasMore: true` means older messages exist beyond \
                the returned page.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "channelId": ["type": "string"],
                        "limit": ["type": "integer"],
                        "before": ["type": "string"],
                    ],
                    "required": ["channelId"],
                ]
            ),
            handler: { args in
                let channelId = args["channelId"]?.stringValue ?? ""
                let limit = args["limit"]?.intValue ?? 50
                let before = args["before"]?.stringValue
                return await MainActor.run {
                    guard let s = slackData(store, myAppId: myAppId) else {
                        return .object(["ok": .bool(false), "error": "no slack component"])
                    }
                    let all = (s.messagesByChannel[channelId] ?? [])
                        .sorted { $0.timestamp < $1.timestamp }
                    let pool: [SlackMessage]
                    if let before, !before.isEmpty,
                       let cursorIdx = all.firstIndex(where: { $0.id == before }) {
                        pool = Array(all.prefix(cursorIdx))
                    } else {
                        pool = all
                    }
                    let cap = max(0, limit)
                    let trimmed = Array(pool.suffix(cap))
                    let hasMore = pool.count > trimmed.count
                    let formatter = ISO8601DateFormatter()
                    let entries: [AnyJSON] = trimmed.map { m in
                        .object([
                            "id": .string(m.id),
                            "channelId": .string(m.channelId),
                            "authorKind": .string(m.authorKind.rawValue),
                            "authorId": .string(m.authorId),
                            "text": .string(m.text),
                            "timestamp": .string(formatter.string(from: m.timestamp)),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "messages": .array(entries),
                        "totalMessages": .int(all.count),
                        "hasMore": .bool(hasMore),
                    ])
                }
            }
        ))

        // --- Posting (sub-agents only) -------------------------

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackPostMessage",
                description: """
                Post a message into a Slack channel as the running \
                agent. Use this when you want to say more than one \
                thing in a turn (e.g. "looking…" → run a tool → \
                "here it is"). If you don't call this and end your \
                turn with a normal assistant message, your final \
                reply is auto-posted for you, so simple Q&A \
                doesn't need this tool. Any `@mentions` in `text` \
                fan out — each mentioned agent is invoked \
                synchronously on the same channel, returning their \
                final reply through this tool result. Reentrancy + \
                a chain-depth cap prevent infinite call loops. \
                Result echoes \
                {messageId, channelId, fanOut: [{agentId, outcome, text?, error?}]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "channelId": ["type": "string"],
                        "text": ["type": "string"],
                    ],
                    "required": ["channelId", "text"],
                ]
            ),
            handler: { args in
                let channelId = args["channelId"]?.stringValue ?? ""
                let text = args["text"]?.stringValue ?? ""
                guard let currentAgentId = context.currentAgentId else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("slackPostMessage requires a sub-agent context — only invoked agents can post."),
                    ])
                }
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedText.isEmpty else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("text must be non-empty"),
                    ])
                }
                // Snapshot @mentions BEFORE posting — we want the
                // text the agent actually wrote, not whatever the
                // store coerces. Mentions resolve against the filesystem roster.
                let rosterSnapshot = await MainActor.run {
                    memory.map { AgentStore(memory: $0).agents } ?? []
                }
                let mentions = SlackView.parseMentions(text: trimmedText, agents: rosterSnapshot)
                // Resolve componentId for the store mutator.
                let componentId = await MainActor.run {
                    store.slackComponentId(myAppId: myAppId)
                }
                guard let componentId else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("no slack component"),
                    ])
                }
                let messageId = await MainActor.run {
                    store.slackPostMessage(
                        channelId: channelId,
                        authorKind: .agent,
                        authorId: currentAgentId,
                        text: trimmedText,
                        mentionedAgentIds: mentions,
                        myAppId: myAppId,
                        componentId: componentId
                    )
                }
                guard let messageId else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("could not post — channel not found"),
                    ])
                }
                await context.markMessagePosted(currentAgentId)
                // Fan out to each @mention sequentially. Sequential
                // (not parallel) so the invocation stack grows
                // predictably and the chain-depth guard sees one
                // nested level at a time.
                var fanOut: [AnyJSON] = []
                for targetId in mentions {
                    let outcome = await context.invoke(targetId, channelId)
                    fanOut.append(Self.encodeFanOutOutcome(agentId: targetId, outcome: outcome))
                }
                return .object([
                    "ok": .bool(true),
                    "messageId": .string(messageId),
                    "channelId": .string(channelId),
                    "fanOut": .array(fanOut),
                ])
            }
        ))

        // --- Admin (main chat only) ----------------------------
        //
        // Subagents are authored as `pupa/agents/<slug>/AGENTS.md` files (via
        // the memory tools or the Slack create-agent UI) — there is no
        // `slackCreateAgent` tool. Channel setup stays here.

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackCreateChannels",
                description: """
                Create one or more channels / group DMs / 1-on-1 DMs \
                in this MyApp's Slack canvas. Always pass a `channels` \
                array — wrap a single channel as `[{ ... }]`. Each entry \
                is `{name, type, memberAgentIds?}`. `type` is one of \
                "channel", "groupDM", "dm". Unknown agent ids in \
                `memberAgentIds` are silently dropped (call \
                slackListAgents first to resolve names). Refused \
                if the caller is itself a Slack agent — only the \
                main chat agent can manage channels in v1. Result \
                echoes {created: [{channelId, name, type}]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "channels": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": ["type": "string"],
                                    "type": ["type": "string", "enum": ["channel", "groupDM", "dm"]],
                                    "memberAgentIds": [
                                        "type": "array",
                                        "items": ["type": "string"],
                                    ],
                                ],
                                "required": ["name", "type"],
                            ],
                        ],
                        "componentId": componentIdSchema(kind: "slack"),
                    ],
                    "required": ["channels"],
                ]
            ),
            handler: { args in
                if context.currentAgentId != nil {
                    return Self.adminForbiddenResult()
                }
                let componentIdArg = args["componentId"]?.stringValue
                let entries = args["channels"]?.arrayValue ?? []
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "slack", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    var created: [AnyJSON] = []
                    for entry in entries {
                        let obj = entry.objectValue ?? [:]
                        let name = obj["name"]?.stringValue ?? ""
                        let typeStr = obj["type"]?.stringValue ?? ""
                        let memberIds = (obj["memberAgentIds"]?.arrayValue ?? [])
                            .compactMap { $0.stringValue }
                        guard let type = SlackChannelType(rawValue: typeStr) else { continue }
                        if let id = store.slackAddChannel(
                            name: name,
                            type: type,
                            memberAgentIds: memberIds,
                            myAppId: myAppId,
                            componentId: resolvedId
                        ) {
                            created.append(.object([
                                "channelId": .string(id),
                                "name": .string(name),
                                "type": .string(typeStr),
                            ]))
                        }
                    }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
                        "created": .array(created),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackAddAgentsToChannel",
                description: """
                Add one or more agents to a channel's member \
                roster. `channelId` + `agentIds` (array; pass `[id]` \
                for a single agent). Idempotent — already-present \
                ids are skipped. Refused for sub-agent callers. \
                Result echoes {channelId, added}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "channelId": ["type": "string"],
                        "agentIds": [
                            "type": "array",
                            "items": ["type": "string"],
                        ],
                        "componentId": componentIdSchema(kind: "slack"),
                    ],
                    "required": ["channelId", "agentIds"],
                ]
            ),
            handler: { args in
                if context.currentAgentId != nil {
                    return Self.adminForbiddenResult()
                }
                let componentIdArg = args["componentId"]?.stringValue
                let channelId = args["channelId"]?.stringValue ?? ""
                let agentIds = (args["agentIds"]?.arrayValue ?? [])
                    .compactMap { $0.stringValue }
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "slack", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    let changed = store.slackAddAgentsToChannel(
                        channelId: channelId,
                        agentIds: agentIds,
                        myAppId: myAppId,
                        componentId: resolvedId
                    )
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
                        "channelId": .string(channelId),
                        "added": .bool(changed),
                    ])
                }
            }
        ))
    }

    /// Resolve the MyApp's `SlackData` body when it holds exactly one slack
    /// component — else nil. The active/view component is never consulted.
    /// Mirrors `tracker(_:myAppId:)` etc.
    @MainActor
    private static func slackData(_ store: MyAppStore, myAppId: UUID) -> SlackData? {
        guard case .resolved(let id) = store.resolveWriteTarget(kind: "slack", componentId: nil, myAppId: myAppId),
              let myApp = store.myApps.first(where: { $0.id == myAppId }),
              let comp = myApp.components.first(where: { $0.id == id }),
              case .slack(let s) = comp.body else { return nil }
        return s
    }

    /// JSON-encode one fan-out outcome for inclusion in the
    /// `slackPostMessage` tool result. Reentrancy / busy /
    /// max-depth all surface as `{ok: false, error}` rows so the
    /// invoking agent can react without parsing free-form text.
    ///
    /// TODO(#193 follow-up): bring this echo to parity with
    /// `invokeMyAppAgent`'s `agent_unavailable` payload — surface
    /// `target` (as `AgentInvocationKey.wireValue`), `callPath`, and
    /// `treeRootedAt` so a Slack agent can reason about the forest
    /// programmatically instead of only reading the human-readable
    /// `error` string. Requires plumbing the rejection's structured
    /// fields through `SlackInvoker.InvocationOutcome`, which today
    /// only carries `targetName` + `depth`.
    private static func encodeFanOutOutcome(
        agentId: String,
        outcome: SlackInvoker.InvocationOutcome
    ) -> AnyJSON {
        switch outcome {
        case .completed(let text, let messageId):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("completed"),
                "text": .string(text),
                "messageId": messageId.map { AnyJSON.string($0) } ?? .null,
            ])
        case .reentrant(let name):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("reentrant"),
                "error": .string("@\(name) invoked you earlier — they're waiting on your reply. Finish your turn before calling them again."),
            ])
        case .busy(let name):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("busy"),
                "error": .string("@\(name) is already replying in a parallel turn — try again once they finish."),
            ])
        case .maxDepthExceeded(let name, let depth):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("max_depth_exceeded"),
                "error": .string("Cannot invoke @\(name): agent chain already \(depth) deep. Reply directly instead of asking another agent."),
            ])
        case .budgetExhausted(let name, let n):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("budget_exhausted"),
                "error": .string("Turn budget with @\(name) exhausted after \(n) turns. Start a new conversation to re-engage."),
            ])
        case .failed(let error):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("failed"),
                "error": .string(error),
            ])
        }
    }

    private static func adminForbiddenResult() -> AnyJSON {
        .object([
            "ok": .bool(false),
            "error": .string("Only the main chat agent can manage Slack agents and channels. Ask the user to create what you need."),
        ])
    }
}
