---
name: pr-review
description: Review the current PR branch end-to-end for implementation gaps, introduced bugs, missing test coverage, code cleanliness against repo conventions, and performance regressions. Use when the user says "/pr-review", "review the PR", "review this branch", or wants a holistic critique of the branch's diff versus its stated goal.
---

# PR Review

Review the current PR branch as a thoughtful reviewer would. Diff the branch against its base, understand what it is trying to fix, then judge the work against the questions below.

## Steps

1. Find the base and diff. Determine the PR's base branch (see this repo's `CONTRIBUTING.md` — Pupa branches from and merges to `dev`, not `main`). Get the full diff and the list of changed files:
   - `git log --oneline <base>..HEAD` for intent
   - `git diff <base>...HEAD` for the change
2. Read the branch's stated goal — PR description, commit messages, linked issue, or ask the user if unclear.
3. Read the changed files in full (not only the diff hunks) so you judge changes in context.

## What to assess

- **Implementation gaps** — Does the change actually accomplish what it set out to do? Any half-done paths, unhandled cases, or TODOs left behind?
- **Bugs introduced** — Any new correctness problems, regressions, broken edge cases, or bad assumptions in the diff?
- **Missing coverage** — Is what it fixes backed by tests? Would the bug it addresses be caught if it regressed? Note untested paths.
- **Cleanliness / fit** — Is it written the way this repo works? Follows conventions in the repo's `CLAUDE.md` (e.g. canvas mutations only via `CanvasState`, agent behaviour via frontend tools, prompts minimal and decoupled, docs updated on behaviour changes, version bumped). No duplicated logic, dead code, or leaked personal info.
- **Performance** — Any new hot-path cost, O(n²) loops, redundant work, extra allocations, or blocking calls on the main thread?

## Output

Give a concise, prioritized report. Lead with anything blocking. For each finding: `file:line` — what's wrong — suggested fix. Call out what's good briefly. End with a clear verdict: ship, ship-with-nits, or needs-work.
