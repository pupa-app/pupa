# Slack component

Multi-agent chat rooms. A thin UI + message-routing layer over **generic
subagents** — see [Subagents](../architecture.md#subagents) for the primitive.

## Mental model

Agents are **not** stored in the component. They are filesystem subagents
(`pupa/agents/<slug>/AGENTS.md`) discovered by `AgentStore`; a Slack workspace's
roster is *all* subagents in the MyApp. The component owns only rooms + history.

## Data model — `SlackData` ([Canvas/CanvasState.swift](../../Pupa/Sources/PupaApp/Canvas/CanvasState.swift))

- `channels: [SlackChannel]` — `channel` / `groupDM` / `dm`; `memberAgentIds`
  holds **subagent slugs**.
- `messagesByChannel: [String: [SlackMessage]]` — `authorId` is `"user"` or a
  subagent slug.
- `activeChannelId`.

No `agents` field. A legacy `agents` key in an old on-disk blob is ignored.

## Mutators ([MyApps/MyAppStore.swift](../../Pupa/Sources/PupaApp/MyApps/MyAppStore.swift))

`slackAddChannel`, `slackAddAgentsToChannel`, `slackSetActiveChannel`,
`slackPostMessage`, `slackOpenDM(agentId:displayName:)`. Member/author ids are
subagent slugs, stored verbatim — roster validation is the caller's job (the
tools/UI check against `AgentStore`).

## Tool surface ([Tools/AppTools.swift](../../Pupa/Sources/PupaApp/Tools/AppTools.swift) `registerSlackTools`)

- **Discovery** (any caller): `slackListAgents` (backed by `AgentStore`),
  `slackListChannels`, `slackReadChannelHistory`.
- **Posting** (sub-agents only): `slackPostMessage` — posts as the running
  subagent; `@mentions` fan out through `invokeSlackAgent`.
- **Channel admin** (main chat only): `slackCreateChannels`,
  `slackAddAgentsToChannel`.

To create an agent, write `pupa/agents/<slug>/AGENTS.md` (via the memory tools
or the new-agent UI, which calls `AgentStore.createAgent`) — there is no
`slackCreateAgent` tool.

## Runtime

@-mentioning an agent (or posting in a DM) →
`ChatSessionCoordinator.invokeSlackAgent`, a Slack wrapper over the generic
`runSubagent`: it resolves the subagent from `AgentStore`, adds channel-history
context (`slackInvocationPrompt`), streams live tool-call bubbles through
`SlackInvoker`, and auto-posts the final reply unless the agent already called
`slackPostMessage`. Gated by `AgentInvocationGate` under `.subagent(myAppId:slug:)`.

## Export

`SlackExportPolicy` keeps channels, strips the transcript. Agent personas travel
separately as the `pupa/agents/` memory files in the bundle.
