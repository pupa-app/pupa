# Templates — the realism bar

How to build a `.pupa` template that reads like a **real instance of a real
app** the user can augment, not a feature demo. Code:
[Pupa/Sources/PupaApp/MyApps/](../Pupa/Sources/PupaApp/MyApps/) (one
`*Example.swift` per template, registered in
[ExampleRegistry.swift](../Pupa/Sources/PupaApp/MyApps/ExampleRegistry.swift)).
Export format: [marketplace.md](marketplace.md). Build recipe (new shape):
[adding-a-component.md](adding-a-component.md).

## Realism rubric

A template ships only when it meets all of:

1. **Plausible seed data** — real names + numbers in believable ranges, no
   `foo`/lorem. Dates computed relative to `Date()`, never hardcoded.
2. **A real recurring workflow, not a feature tour** — the app `AGENTS.md`
   "How to use" is a numbered loop a real person repeats.
3. **Cross-component links** — items reference each other via `linkedItems` /
   `ComponentItemRef` so it's one app, not 4 widgets.
4. **Grounded in a documented use case** — `AGENTS.md` + the index below cite
   the real source the template ports.
5. **Names the real tools/MCPs the agent uses** — personas reference concrete
   backend tools (`tavily_search`, RSS/HN, weather/GitHub MCP…) so the agent
   actually fetches data instead of hand-waving.
6. **Personas that hand off** — each `slack` agent carries a "what you don't
   do" boundary (see `ContentStudioExample`).
7. **Honest capability boundaries** — state what needs a tool/skill/MCP to work
   (see the `DevWorkspaceExample` shell-tool section).
8. **Exports + re-imports clean** — only kinds with a `ComponentExportPolicy`;
   passes `ComponentExportRegistry.assertComplete` + the CI completeness test.
9. **Augmentable, not finished** — enough rows to be useful day one, few enough
   that it's obviously a starting point to edit.
10. **Self-maintaining** — instructs the agent to keep *itself* updated, not
    just the canvas. See below.

## Keeping yourself updated (rubric #10)

Templates close a learning loop so the agent gets better with use (adapted from
Hermes' memory + skills + self-improvement pillars — **no new tools**; uses
`writeMemoryFile` / `readMemoryFile` / `lsMemories` against the per-app memory
root `MemoryStore.appRoot(myAppName:)`). Each app `AGENTS.md` embeds a
**"## Keeping yourself updated"** section telling the agent to:

- Maintain `MEMORY.md` (app/project facts) + `USER.md` (the user's preferences
  / working style) at the app memory root — keep them **compact** (a few
  hundred words each), pruning stale lines rather than appending forever.
- Keep a `skills/` folder: after a repeated/complex task, write a short
  reusable skill note (trigger + steps); when it misfires, **fix the trigger**
  rather than rewrite it.
- Run a **periodic self-review** at the template's natural cadence — update
  `MEMORY.md`, prune, and propose edits to its own persona `AGENTS.md` for
  conventions it has learned. Persona files are editable memory and survive
  restore (`seedAgentsMd` is file-exists-guarded).
- **Confirm before overwriting** a user-edited memory/persona. Pupa has no
  staged-write/approve queue — surface the proposed update in chat and write on
  confirm; never silently clobber a user edit.

## Grounded reference index

| Template | Real use case it ports | Source |
|---|---|---|
| Content Studio | content pipeline: research → outline → draft → publish | [Hermes use cases](https://www.hostinger.com/tutorials/hermes-agent-use-cases) |
| Research / Competitive Intel | parallel competitor research → comparison table; weekly "what's new since last week" | [Hermes use cases](https://www.hostinger.com/tutorials/hermes-agent-use-cases) |
| Daily Briefing | 7am briefing: weather + calendar + top-5 HN AI + GitHub notifs, <500 words | [Hermes use cases](https://www.hostinger.com/tutorials/hermes-agent-use-cases) |
| Dev Workspace | scheduled system maintenance / disk + process audit | [Hermes use cases](https://www.hostinger.com/tutorials/hermes-agent-use-cases) |

Self-improvement pattern grounded in Hermes' five pillars (memory, skills,
soul, crons, self-improvement) — see the
[Hermes memory docs](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/memory.md).

## Backlog

The full template backlog + acceptance criteria live in issue #54.
