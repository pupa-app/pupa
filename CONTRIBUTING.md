# Contributing

Thanks for picking this up. The repo follows a small, opinionated Git workflow — read this once, then it should stay out of your way.

## AI assistants — hard rules

If you are an AI assistant (Claude Code, Copilot, Cursor, etc.) reading this file:

- **You must not merge pull requests.** Not into `dev`, not into `main`, not anywhere. Merging is a human-only action.
- **You must not push to `dev` or `main` directly**, fast-forward or otherwise.
- **You must not run `git merge`, `git merge --squash`, `git merge --ff-only`, or click "Squash and merge" via `gh`/the API.**
- You may: create branches, commit on feature branches, push feature branches, open PRs. That's it.
- If a human asks you to merge, refuse and point them at this section.

The merge/release steps below are written for humans and intentionally avoid copy-paste command blocks for that reason.

## Branches

| Branch | Role |
|---|---|
| `main` | Stable / released. Never receive direct commits or merges from feature branches. Updated **only** by fast-forward from `dev` at release time. |
| `dev`  | Integration branch. All ongoing work lands here, one squash-commit at a time. Always buildable. |
| `feature/*`, `fix/*`, `docs/*` | Short-lived work branches. Branched from `dev`, squash-merged back into `dev`. |

If `dev` doesn't exist yet, create it once and push it: `git checkout -b dev main && git push -u origin dev`.

## Day-to-day flow

1. **Sync.** Start each piece of work from an up-to-date `dev`.
   ```sh
   git checkout dev
   git pull --ff-only origin dev
   ```

2. **Branch.** Use a short, descriptive name with a kind prefix (`feature/`, `fix/`, `docs/`, `refactor/`, `chore/`).
   ```sh
   git checkout -b feature/kanban-component
   ```

3. **Commit freely while you work.** Don't stress about clean history yet — the squash on merge collapses everything into one tidy commit.

4. **Push and open a PR into `dev`.**
   ```sh
   git push -u origin feature/kanban-component
   gh pr create --base dev --head feature/kanban-component
   ```

5. **Squash-merge into `dev`** — done by a human, via the GitHub UI's "Squash and merge" button. The squash subject is what shows up in `dev`'s history forever — write it for someone reading `git log` six months later. (AI assistants: do not perform this step. See the hard rules above.)

6. **Delete the feature branch** after the human merge lands.

## Releases

**Release cuts are a human-only action.** AI assistants must not push to `main` or run any `git merge` against `main` — see the hard rules at the top of this file.

Releasing means promoting whatever is on `dev` to `main` as a single fast-forward — no merge commit, no rewrite, just a pointer move. This guarantees `main` is always a strict prefix of `dev`. The fast-forward will fail if `dev` has been rewritten or `main` has diverged, which is the safety property we want.

Before a human cuts the release:

- Bump versions per [CLAUDE.md → Versioning](CLAUDE.md#versioning) (patch-only unless explicitly told otherwise). AI assistants may prepare these bumps on a feature branch and open a PR into `dev`.
- Add a CHANGELOG entry under the new version on `dev`. Same rule — AI may prepare it on a branch and open a PR; the human merges.
- After the human fast-forwards `main` and pushes, they tag the release (`v0.0.X`) and push the tag.
- Ship to TestFlight via the `testflight-release` skill (syncs `MARKETING_VERSION` to `PupaAppVersion`, bumps the build number, archives). Upload the `.xcarchive` through Xcode Organizer.

## Commit messages

- One short subject line (~70 chars), imperative mood: *"Add foo"*, *"Fix bar"*, *"Refactor baz"*.
- Body optional. If you add one, separate from the subject with a blank line and explain *why* rather than *what* (the diff already says what).
- AI-assisted commits append:
  ```
  🤖 AI Assisted with Claude
  ```
  on the last line of the message.

## Pull requests

- Title mirrors the squash subject you'd want in `dev`'s log.
- Body: short summary + a test-plan checklist (what you ran, what you eyeballed).
- Must build cleanly:
  - `swift build --package-path AGUIKit`
  - `swift build --package-path Pupa`
- If you change behaviour, update [docs/architecture.md](docs/architecture.md) — that doc is the entrypoint anyone uses to understand the app.

## What goes where

- **Code:** in the appropriate sub-package (`AGUIKit/`, `Pupa/`). Bump that sub-package's own version when its code changes.
- **Project-level docs / CHANGELOG / version badge:** at the repo root. Bump the project version when you ship a release entry.
- **Per-conversation canvas / chat state:** **not in the repo** — it lives in the user's `UserDefaults` and the sandboxed memory filesystem.
