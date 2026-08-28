---
name: loop-pr-review
description: Review a PR with an adversarial subagent, fix only the blockers, re-review, and repeat until a round comes back with no blockers. Use when the user says "/loop-pr-review", "review this PR until it's clean", "keep reviewing until no blockers", or asks for repeated review rounds on a branch or PR.
---

Review → fix blockers → re-review, until a round returns no blockers. Then stop
and summarise.

## Why loop rather than review once

A fix is written by the same reasoning that produced the bug, so it tends to
reproduce the bug's *class*. Observed on pupa#297:

- Round 1 fixed an `awk … exit` SIGPIPE hazard using `| head -1` — identical defect.
- Round 2 fixed an unreachable guard at one site, missed the sibling site in the
  same file, and the commit claimed the file was done.

Both were caught only because a fresh reviewer looked again. One review round is
not enough when the fix and the bug share an author.

## The loop

1. **Review.** Dispatch a subagent with the prompt below. Read-only.
2. **Triage.** Fix every **blocker**. Should-fix and nit are optional — decide
   with the user, don't silently expand scope.
3. **If any blocker was fixed:** commit, push, comment the findings on the PR,
   go to 1 with the round number incremented.
4. **If a round returns zero blockers:** stop. Summarise.

**Cap at 4 rounds.** If blockers still appear at round 4, stop and escalate: a
file needing that many passes should be rewritten or redesigned, not patched
again.

## The reviewer prompt

Adapt, but keep these — each exists because omitting it let a real bug through:

- **Name the repo, branch, base, and commits.** Say read-only explicitly:
  no modify, commit, push, merge.
- **Say which round it is, and describe what the previous rounds got wrong.**
  This is the highest-value line in the prompt. "Round 1 fixed X by introducing
  the same defect. Assume round 3 did the same. Find it."
- **Demand evidence, not reasoning.** Require a runnable snippet and its real
  output per finding. Shell hazards like SIGPIPE only appear at scale, so ask
  for large-input tests where relevant.
- **Ask it to enumerate exhaustively, not just read the diff.** Round 2's miss
  was a sibling site outside the changed hunks.
- **Ask it to spot-check the PR's own claims.** Measured numbers, "tests pass",
  "all instances fixed". Overclaiming is itself a finding.
- **Require severity per finding**, and that it state plainly when a level is
  empty. End with a one-line merge verdict.
- **Forbid printing secrets** — credentials, keys, local signing config.

## What counts as a blocker

Ships broken output, silently swallows a failure, contradicts a rule the repo
enforces elsewhere, or makes a documented procedure fail on first use. Style,
naming, and unexercised edge cases are not blockers.

## Reporting

Each round, tell the user what was found and **who caused it** — if the blocker
came from your own previous fix, say so plainly. Comment the round's findings on
the PR so the history is visible to a human reader.

Correct any overclaim the reviewer catches in an earlier commit message or PR
description, in the next commit message. Don't quietly drop it.

The final summary states: rounds run, blockers fixed per round, what remains
unfixed and why, and whether the PR is merge-ready.

## Don't

- Don't fix should-fixes and nits during the loop without asking — it inflates
  the diff and makes each round harder to review.
- Don't skip the re-review after fixing. That is the entire point.
- Don't let the reviewer merge, push, or edit. It reviews.
- Don't claim a fix is verified end-to-end when only its logic was exercised in
  isolation. Say which one it was.
