---
name: feature-duel
description: Run a competitive implementation of one feature. Two agents plan and implement the same task in parallel isolated worktrees, each opens a PR; a judge compares them, picks the winner, and grafts the loser's salvageable bits onto it. Stops at graft — a human merges. Use when the user says "/feature-duel", "duel this feature", "have two of you implement X and pick the best", or wants competing PRs compared and merged-down.
---

# Feature Duel

Point this at one feature or bugfix. It spawns two independent implementations (different lenses so they actually differ), opens two PRs, then a third agent picks the winner and grafts the loser's good bits onto it. It stops at the graft, leaving the winner PR ready to merge.

## When to use

The task is well-scoped enough to hand off whole, and worth the cost of ~6 agent runs (2 plan + 2 build + judge + graft) to get a compared, best-of-two result. For a quick change, just implement it directly.

## How to run

1. Get the task from the user — the feature/bug to implement, in enough detail that a fresh agent could do it without follow-up. If vague, ask first.
2. Confirm the base branch. Pupa branches from `dev` (see `CONTRIBUTING.md`). Default `dev`.
3. Run the workflow at `.claude/skills/feature-duel/duel.workflow.js`, passing the task and base as args:

   ```
   Workflow({
     scriptPath: ".claude/skills/feature-duel/duel.workflow.js",
     args: { task: "<the feature description>", base: "dev" }
   })
   ```

   Invoking this skill is the user's explicit opt-in to multi-agent orchestration — running the workflow here is expected.
4. When it returns, report to the user: both PR urls, the winner + why, what was grafted from the loser, and the reminder that **they** merge the winner.

## What the workflow does

- **Plan ×2** — two agents plan the same task under different lenses (`minimal` = smallest correct diff, `clean` = best design for the repo). Plan only, no code.
- **Build ×2** — each implements its plan in its own `git worktree` (parallel edits can't collide), runs `make test`, commits, pushes, opens a PR. No merge.
- **Judge** — a third agent reads both PRs via `gh`, scores them on gaps / bugs / coverage / cleanliness / performance, picks the winner, and lists concrete salvage items from the loser.
- **Graft** — applies the salvage items onto the winner's branch (cherry-pick or re-implement, never `git merge`), keeps `make test` green, updates the winner PR, and comments what came from the loser.

## Guardrails

- **The workflow itself doesn't merge.** Both PRs come back open; the winner is merged afterwards, by you or by whoever asked.
- **No self-signing, no personal info** in commits/PRs (repo rule).
- CI here is billing-blocked — build agents verify with local `make test`, not green checks.
- Tune the two lenses in `duel.workflow.js` (`LENSES`) if you want a different axis of competition (e.g. perf-first vs readability-first).
