# Contributing

Thanks for picking this up. This is the [pupa-app/pupa](https://github.com/pupa-app/pupa)
client for [Pupa](https://pupa-app.com) — the native iOS / macOS app.
Below: how to build it, how it fits together, and the small,
opinionated Git workflow the repo follows.

## AI assistants — hard rules

If you are an AI assistant (Claude Code, Copilot, Cursor, etc.) reading this file:

- **You must not merge pull requests.** Not into `dev`, not into `main`, not anywhere. Merging is a human-only action.
- **You must not push to `dev` or `main` directly**, fast-forward or otherwise.
- **You must not run `git merge`, `git merge --squash`, `git merge --ff-only`, or click "Squash and merge" via `gh`/the API.**
- You may: create branches, commit on feature branches, push feature branches, open PRs. That's it.
- If a human asks you to merge, refuse and point them at this section.

The merge/release steps below are written for humans and intentionally avoid copy-paste command blocks for that reason.

## Layout

```
pupa/
├── AGUIKit/      ← standalone Swift Package, the AG-UI client.
│                   Could be published independently — no dependency on Pupa.
├── Pupa/         ← the app proper. Depends on ../AGUIKit (local SPM path),
│                   plus SwiftUI views, @Observable stores, tool handlers.
├── PupaHost/     ← thin Xcode app project (PupaHost.xcodeproj) that hosts
│                   PupaApp on iOS / macOS via SPM. Used for TestFlight builds.
└── docs/         ← architecture + "adding a new component" recipe.
```

`AGUIKit` is meant to be **the AG-UI client library that doesn't exist
in the Swift ecosystem yet** — equivalent to what `@copilotkit/runtime`
+ `@copilotkit/react-core` do for browsers. By keeping it isolated,
anyone building any AG-UI agent client on Apple platforms can reuse it
without taking on Pupa's UI choices.

Each package carries its own patch-only version:

| Component | Version file |
|---|---|
| **Pupa iOS / macOS app** (SwiftUI) | [`Pupa/Sources/PupaApp/Version.swift`](Pupa/Sources/PupaApp/Version.swift) |
| **AGUIKit** (Swift Package — AG-UI client) | [`AGUIKit/Sources/AGUIKit/Version.swift`](AGUIKit/Sources/AGUIKit/Version.swift) |

## Run

### macOS demo (fast iteration outside Xcode)

```bash
# 1. Start a backend on :8004 (see https://github.com/pupa-app/pupa-backend).
# 2. Run the macOS demo:
make mac-demo            # = swift run --package-path Pupa PupaDemo
```

The demo defaults to `http://localhost:8004/`. Override by passing
`backendURL:` to `AppView` in `Pupa/Sources/PupaDemo/App.swift`, or via
Settings → Backend inside the running app.

> **The demo does not share data with the Xcode build.** `PupaDemo` is a plain
> SwiftPM executable, so it is unsandboxed and stores everything under
> `~/Library/Application Support/pupa`. `PupaHost` is sandboxed, so the same
> tree lives inside its container. Expect two separate rosters; it is not data
> loss.

### iOS / macOS app via Xcode

Open `PupaHost/PupaHost.xcodeproj` in Xcode 16+; the host app pulls in
`PupaApp` via the workspace's pinned SPM dependencies. Select an iOS
simulator or "My Mac (Designed for iPad)" and run.

> **Signing.** `DEVELOPMENT_TEAM` is intentionally blank in the checked-in
> project. Before running on a device or archiving for TestFlight, put your
> own team in `PupaHost/Local.xcconfig` (git-ignored, one line
> `DEVELOPMENT_TEAM = XXXXXXXXXX`), or pass
> `xcodebuild DEVELOPMENT_TEAM=...`. Do **not** use the `PupaHost` target →
> Signing & Capabilities dropdown: it writes the team back into
> `project.pbxproj` and leaks it into the repo. The `testflight-release`
> skill does not set it for you.

### Tests

Run the suite with `make`, not raw `swift test` — the targets cover both
packages and pin Pupa's `--no-parallel` (its disk tests share one
overridden storage root).

```bash
make test                # both packages
make test-aguikit        # AGUIKit only (use FILTER=Foo to scope)
make test-pupa           # PupaApp only
```

## Architecture

```
   ┌─────────────────────────────────────┐
   │  Pupa (SwiftUI app)                 │
   │   • Canvas (tracker / calendar /    │   ────── AG-UI ───────▶   Pupa backend
   │     checklist / slack / …)          │      POST / (SSE)          (FastAPI on :8004)
   │   • Chat + slash commands           │
   │   • Frontend tools (canvas + mem)   │
   │   • Memories filesystem             │
   │   • UserDefaults state              │
   │                                     │
   │     uses ─▶  AGUIKit                │
   │                • AgentClient/Session│
   │                • multi-round loop   │
   │                • ToolRegistry       │
   └─────────────────────────────────────┘
```

Key facts:

- **Canvas mutations only via `CanvasState`
  ([Pupa/Sources/PupaApp/Canvas/CanvasState.swift](Pupa/Sources/PupaApp/Canvas/CanvasState.swift))
  or registered frontend tools.** No duplicate mutation logic in views.
- **Shapes are SwiftUI views**, not generative-UI primitives. Adding one
  = small self-contained change — recipe at
  [docs/adding-a-component.md](docs/adding-a-component.md).
- **Agent behaviour primarily via frontend tools** registered in
  [`AppTools.swift`](Pupa/Sources/PupaApp/Tools/AppTools.swift). The
  backend forwards their JSON-Schema definitions to the model; the client
  executes them.
- **Memories are persistent**; canvas + chat state reset on "New
  session" but the markdown filesystem at
  `~/Library/Application Support/pupa/memories/` survives.

Full reference in [docs/architecture.md](docs/architecture.md).

## Backend

The backend lives in a separate repo —
[pupa-app/pupa-backend](https://github.com/pupa-app/pupa-backend).
Install + run + pair-once auth flow are documented there. The client
defaults to `http://localhost:8004/`; point it at a hosted instance via
Settings → Backend.

## Build your own component

The most useful thing you can contribute is a new piece of the app.

- **A canvas shape** is a SwiftUI view, a typed `Codable` model, and the
  render + mutator tools the agent calls. Kind registration lives on
  `MyAppType`. Full recipe, including the tests and the export policy:
  [docs/adding-a-component.md](docs/adding-a-component.md). Existing
  shapes are documented in [docs/components/](docs/components/).
- **A MyApp template** is a `.pupa` bundle, no Swift involved. It has to
  clear the realism bar in [docs/templates.md](docs/templates.md) before
  it ships as an `ExampleMyApp`.
- **A skill** is markdown in a MyApp's `pupa/` folder, surfaced as a slash
  command and as a model-loadable playbook: [docs/skills.md](docs/skills.md).

## TestFlight

The `testflight-release` skill at
[`.claude/skills/testflight-release/`](.claude/skills/testflight-release/)
syncs `MARKETING_VERSION` to `PupaAppVersion`, bumps
`CURRENT_PROJECT_VERSION`, and produces a `.xcarchive` ready for upload
via Xcode Organizer. It also gates the macOS archive on its signed
entitlement set, so an unused capability can't reach App Store review —
see [Signing & build configuration](docs/architecture.md#signing--build-configuration).
Invoke through Claude Code's `/testflight-release`, or run the script
directly:

```bash
.claude/skills/testflight-release/archive.sh [--build N] [--no-bump] [--skip-icon-check] [--no-flow]
```

## DMG (direct download)

The `dmg-release` skill at
[`.claude/skills/dmg-release/`](.claude/skills/dmg-release/) builds the
notarized `.dmg` for the download-from-the-website channel: Developer ID
archive, export, entitlement + embedded-profile check, DMG, `notarytool
submit --wait`, `stapler staple`. Invoke through Claude Code's
`/dmg-release`, or run it directly:

```bash
.claude/skills/dmg-release/release.sh --notary-profile <name>
.claude/skills/dmg-release/release.sh --skip-notarize   # local validation only
```

It needs three things that only an Account Holder can create — a Developer ID
Application certificate, a Developer ID provisioning profile for
`com.pupa-app.client` **including the iCloud container**, and stored
`notarytool` credentials. The script refuses to run until all three exist. See
[Distribution channels](docs/architecture.md#distribution-channels) for why the
embedded profile matters.

Never publish a `--skip-notarize` build: Gatekeeper refuses it everywhere except
the machine that built it.

### Publishing a DMG

The DMG is distributed as a GitHub Release asset on this repo — attached to the
release, not committed, so the repository never carries binaries. Tag first
(human step), then:

```bash
git tag v0.0.X && git push origin v0.0.X
.claude/skills/dmg-release/release.sh --notary-profile <name> --publish
```

`--publish` attaches the DMG to a **draft** release for tag `v0.0.X`, using that
version's CHANGELOG section as the notes, and prints the URL. A human reviews and
publishes it. It is refused for un-notarized builds, since publishing one would
hand users a download their Mac won't open.

The asset is uploaded as `Pupa.dmg` — a constant filename, so
`releases/latest/download/Pupa.dmg` stays a permanent link the website can
hardcode. The version lives in the tag and title.

**While this repo is private, release downloads require a GitHub login.** The
link in the README only works for everyone once the repo is public.

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
- Must build and test cleanly: `make build && make test` (see [Run](#run)).
- If you change behaviour, update [docs/architecture.md](docs/architecture.md) — that doc is the entrypoint anyone uses to understand the app.

## Licensing of contributions

The repo carries two licenses, split by role:

| Path | License |
|---|---|
| `AGUIKit/` | **MIT** — [AGUIKit/LICENSE](AGUIKit/LICENSE) |
| Everything else | **MPL-2.0** — [LICENSE](LICENSE) |

By opening a PR you license your contribution under whichever of the two
covers the files you touched. Inbound terms are identical to outbound —
there is **no CLA**, and you keep copyright on your own work.

Three things worth knowing:

- **MPL-2.0 is file-level copyleft.** Modify an MPL file and that file's
  changes stay MPL. It imposes nothing on larger works, so the app still
  combines with proprietary code and ships on the App Store cleanly.
- **New files.** Adding a file to an MPL directory means it's MPL. We use
  the directory-level notice MPL-2.0 permits in Exhibit A, so no per-file
  header is needed — don't add one.
- **Moving code across the boundary.** MIT → MPL is fine. **MPL → MIT is
  not**: lifting code out of `Pupa/` into `AGUIKit/` relicenses it, which
  nobody but the copyright holder may do. If a refactor wants to promote
  app code into AGUIKit, flag it in the PR so it can be handled
  deliberately.

## What goes where

- **Code:** in the appropriate sub-package (`AGUIKit/`, `Pupa/`). Bump that sub-package's own version when its code changes.
- **Project-level docs / CHANGELOG / version badge:** at the repo root. Bump the project version when you ship a release entry.
- **Per-conversation canvas / chat state:** **not in the repo** — it lives in the user's `UserDefaults` and the sandboxed memory filesystem.
