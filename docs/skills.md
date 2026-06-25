# Skills

A **skill** is a reusable playbook the agent loads on demand — Pupa's take on
[Claude Code skills](https://code.claude.com/docs/en/skills). Skills live in a
MyApp's `pupa/` config folder and are picked up automatically by every agent
in that MyApp (main agent + Slack subagents); the orchestrator has its own.

## The `pupa/` config folder

```
memories/<myapp-slug>/pupa/
  AGENTS.md                 # main agent prompt
  agents/<sub>/AGENTS.md    # subagent prompt (overrides inline persona)
  skills/<name>/SKILL.md    # a skill — directory name is the /command
```

`pupa/` is **visible** (not a dotfolder) so it rides the memory sidebar,
per-turn snapshot, and the `.pupaapp` bundle unchanged. Files must be `.md` or
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
into **every** MyApp — not just examples — idempotently at launch
(`seedAll`, over current apps + all example types) and on app creation
(`MyAppStore.addMyApp`). File-exists-guarded, so user/agent edits survive.
Today the only default is `/to-memory`: it distils durable, app-level learnings
from the conversation (conventions, preferences, mid-task realignments) into
`pupa/MEMORIES.md`, which rides the `.pupaapp` export bundle as config.

## Deferred (not v1)

`allowed-tools`, `model`, `context: fork`, `agent`, `hooks`, `paths`,
non-markdown supporting files, and a global cross-app skills tier.

## Code map

- `Skill`, `SkillFrontMatter`, `SkillStore` — `Pupa/Sources/PupaApp/Skills/`.
- Discovery: `SkillStore.rescan()` walks `pupa/skills/*/SKILL.md`; refreshed on
  memory mutation.
- Slash: `SkillStore.slashCommands()` feeds `SlashCommandRegistry`'s live
  `skillProvider` (built-ins win on name collision).
- Model surface: `ChatViewModel.skillsContextEntry` (in all three context
  paths) + the `app_skill_view` tool (`AppTools.registerSkillTools`), always
  advertised via `MyAppType.skillToolNames`.
