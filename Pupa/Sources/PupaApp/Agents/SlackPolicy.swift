import Foundation

// MARK: - SlackPolicy

/// `AgentPolicy` for a Slack agent invocation.
///
/// A Slack agent is always scoped to a specific MyApp (it inherits the
/// MyApp's canvas + memory surface) but runs with an additional "persona"
/// context entry derived from the agent's `AGENTS.md` sub-file.
///
/// Memory root:  `<sandbox>/myapps/<name>/` (same as `MyAppPolicy`)
/// System prompt: `<root>/<agentSubfolder>/AGENTS.md` → persona entry.
/// Tools:         same as `MyAppPolicy` plus any Slack-specific tools.
///
/// `SlackPolicy` is used by `SlackInvoker` to build the per-invocation
/// payload without reaching back into `ChatSessionCoordinator`.
public struct SlackPolicy: AgentPolicy {

    public let myAppId: UUID
    public let agent: SlackAgent
    public let channel: SlackChannel
    public let history: [SlackMessage]

    public init(
        myAppId: UUID,
        agent: SlackAgent,
        channel: SlackChannel,
        history: [SlackMessage]
    ) {
        self.myAppId = myAppId
        self.agent = agent
        self.channel = channel
        self.history = history
    }

    // MARK: - AgentPolicy

    @MainActor
    public func payload(for scope: ChatScope, store: MyAppStore) async -> AgentPayload {
        let myApp = store.myApps.first(where: { $0.id == myAppId })
        let name = myApp?.name ?? ""
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: name))
        // The Slack agent uses the same tool set as the parent MyApp.
        let toolNames = ChatViewModel.allowedToolNames(scope: .myApp(myAppId), store: store, skillState: SkillState())
        // Slack payload system prompt: same base as MyAppPolicy.
        let myAppPolicy = MyAppPolicy(myAppId: myAppId)
        let systemPrompt = await myAppPolicy.payload(for: scope, store: store).systemPrompt
        return AgentPayload(
            systemPrompt: systemPrompt,
            memory: memory,
            toolFilter: { toolNames.contains($0) }
        )
    }

    // MARK: - A2A surface

    /// Slack agents are invoked by Slack; they are not called A2A.
    public func toolsExposedTo(caller: ChatScope?) -> Set<String>? { nil }

    public func canInvoke(from callerScope: ChatScope?) -> Bool { callerScope == nil }
}
