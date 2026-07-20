# Skills

A **skill** is a reusable playbook the agent loads on demand — Pupa's take on
[Claude Code skills](https://code.claude.com/docs/en/skills). Skills live in a
MyApp's `pupa/` config folder and are picked up automatically by every agent
in that MyApp (main agent + Slack subagents); the orchestrator has its own.

## The `pupa/` config folder

```
memories/<myapp-slug>/pupa/
  AGENTS.md                       # main agent prompt
  agents/<sub>/AGENTS.md          # subagent prompt (overrides inline persona)
  skills/<name>/SKILL.md          # a user skill — directory name is the /command
  plugins/<id>/skills/<name>/SKILL.md  # plugin-bundled skill (managed, e.g. the guide)
  automations.json                # canvas-event → action rules (issue #209)
```

`automations.json` is the **app-layer** reactor: declarative rules that
react *inside* Pupa to canvas events (an item dragged into a column) by
proposing a chat. Shape mirrors Claude Code hook config — event-name →
`matcher` → `action` — but the events are Pupa domain events, not harness
hooks. See the rule engine in
[architecture.md](architecture.md#canvas-events--automations-issue-209).
The **host-layer** counterpart (a `/setup` skill that prepares the CLI
*outside* Pupa) is a deferred follow-on.

Skill names share one flat namespace across both roots; on a collision the
`pupa/skills/` skill wins over the plugin one.

`pupa/` is **visible** (not a dotfolder) so it rides the memory sidebar,
per-turn snapshot, and the `.pupa` bundle unchanged. Files must be `.md` or
`.json`; other extensions (executables) are rejected by `MemoryStore` and the
importer — see the threat model in [marketplace.md](marketplace.md).

## SKILL.md

Markdown body + optional YAML-ish frontmatter. The **directory name** is the
`/command` token and the skill id; frontmatter `name` is a display label only.

```markdown
---
description: Draft the weekly digest from the Findings log
when_to_use: when the user asks for the weekly summary
argument-hint: [week]
---
1. Read the latest Findings rows.
2. Lead with the strongest signals.
3. Save to memory under digests/.
```

| Field | Meaning |
|---|---|
| `description` | What it does + when to use it. Listed to the model. |
| `when_to_use` | Extra trigger context, appended to the listing. |
| `argument-hint` | Autocomplete hint, e.g. `[issue]`. |
| `disable-model-invocation` | `true` → only the user `/name` runs it; not listed to the model. |
| `user-invocable` | `false` → hidden from the `/` palette; model-only. |

Body substitutions: `$ARGUMENTS` (full arg string), `$0`/`$1`… (positional,
shell-quoted). If the body references neither and arguments are passed, an
`ARGUMENTS: …` line is appended.

## How a skill is used

- **Slash command.** Palette-visible skills appear in chat as `/<name>`.
  `/deploy prod` shows `/deploy prod` in the transcript and sends the rendered
  SKILL.md body to the agent.
- **Model-invoked (progressive disclosure).** Model-visible skills are listed
  to the agent each turn as `{name, description, when_to_use}` only. The agent
  loads a body on demand with `app_skill_view(name:)`, then follows it — the
  full body costs no tokens until viewed.

Invocation matrix:

| Frontmatter | User `/name` | Model | In context |
|---|---|---|---|
| (default) | yes | yes | description listed |
| `disable-model-invocation: true` | yes | no | not listed |
| `user-invocable: false` | no | yes | description listed |

## Creating a skill

Both the user and the agent can create skills. The agent is told how via an
**always-present** skills context entry (`ChatViewModel.skillsContextEntry`) —
even when the catalogue is empty — which instructs it to `writeMemoryFile` a
`pupa/skills/<name>/SKILL.md` (`<name>` becomes the `/command`). No restart:
the `/` palette and the model's catalogue refresh on the next memory mutation.
The `setup` skill in the Content Studio example is a built-in instance —
seeded as `pupa/skills/setup/SKILL.md`, which is all it takes to provide
`/setup`.

### Default skills (every app)

`DefaultSkills` (`Pupa/Sources/PupaApp/Skills/DefaultSkills.swift`) seeds skills
into **every** MyApp — not just examples. Seeding happens **once, at app birth**
(`MyAppStore.seedBirthFiles`, via `addMyApp` / example restore / the
fresh-install default app), never on later launches, so a user's or agent's
edits *and deletions* stick. File-exists-guarded.

One default ships today, riding the `.pupa` export bundle as config:

- **`/to-memory`** — distils durable, app-level learnings from the conversation
  (conventions, preferences, mid-task realignments) into `pupa/MEMORIES.md` (or
  the relevant `AGENTS.md`).

### Guide skills (all scopes)

`GuideSkills` (`Pupa/Sources/PupaApp/Skills/GuideSkills.swift`) is the
user-facing guide plugin: **`/pupa`** (what Pupa is; the
orchestrator/myapp/component/item boundaries) pointing at five children —
**`/pupa-components`** (shapes + how they combine; kind list generated from
`MyAppType.kinds` so it can't drift), **`/pupa-sharing`** (`.pupa`
export/import), **`/pupa-memory`** (memories, sessions, history, archive),
**`/pupa-agents`** (skills, subagents, slack rooms), **`/pupa-system`** (the
app/backend boundary + where standing behaviour lives — the agent-facing
successor of `/pupa-internals`). All user-invocable and model-loadable via
`app_skill_view`.

The guide lives under `pupa/plugins/pupa-guide/skills/`, not in the user's
`pupa/skills/` space. Unlike default skills it is **managed content**: seeded
into the orchestrator and every MyApp on **every launch**, overwritten when
the shipped `GuideSkills.version` is newer than the file's frontmatter
`version:` — so installs pick up new guide bodies on app update. Edits are
clobbered on the next version bump and deletions resurrect; a custom copy
needs a different skill name. Bodies are user-conceptual only (no
implementation internals) — enforced by tests. The plugin replaced the
retired `/pupa-internals` default skill; a pristine seeded copy of it is
removed on first reseed (a user-modified copy is left alone), and guide
copies an earlier build seeded at the root of `pupa/skills/` (identified by
their managed `version:` frontmatter) are migrated into the plugin.

## App skills vs the backend skills library

The skills here are **app skills** — on-device markdown under `pupa/skills/`,
loaded with `app_skill_view` and created with `writeMemoryFile`. They are the
only skills the user or agent manages from the app. Separately, a **backend**
may expose its own server-side skills library (`~/.pupa-backend/skills/`, read
via a backend `skill_view` tool) — a different store the client never touches.

## Deferred (not v1)

`allowed-tools`, `model`, `context: fork`, `agent`, `hooks`, `paths`,
non-markdown supporting files, and a global cross-app skills tier.

## Code map

- `Skill`, `SkillFrontMatter`, `SkillStore`, `DefaultSkills`, `GuideSkills` —
  `Pupa/Sources/PupaApp/Skills/`.
- Discovery: `SkillStore.rescan()` walks `pupa/skills/*/SKILL.md`; refreshed on
  memory mutation.
- Slash: `SkillStore.slashCommands()` feeds `SlashCommandRegistry`'s live
  `skillProvider` (built-ins win on name collision).
- Model surface: `ChatViewModel.skillsContextEntry` (in all three context
  paths) + the `app_skill_view` tool (`AppTools.registerSkillTools`), always
  advertised via `MyAppType.skillToolNames`.

## Sibling: subagents

`pupa/agents/<slug>/AGENTS.md` is the parallel primitive — Claude-Code-style
delegates discovered by `AgentStore` (mirrors `SkillStore`) and invoked with the
`invoke_agent` tool. Slack agents are these subagents. See
[architecture.md → Subagents](architecture.md#subagents).
