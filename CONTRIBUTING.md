# Contributing

Thanks for picking this up. This is the [pupa-app/pupa](https://github.com/pupa-app/pupa)
client for [Pupa](https://pupa-app.com) — the native iOS / macOS app.
Below: how to build it, how it fits together, and the small,
opinionated Git workflow the repo follows.

## AI assistants — hard rules

If you are an AI assistant (Claude Code, Copilot, Cursor, etc.) reading this file:

**You may, when a human has asked for it in the current session:**

- Create branches, commit on feature branches, push feature branches, open PRs.
- **Squash-merge PRs into `dev`**, once `make test` passes locally and no review
  comment is left unaddressed. Report what you merged.
- **Fast-forward `main` from `dev`** to cut a release — but only when a human
  asks for that step outright. Never initiate a release cut; propose it and wait
  for an explicit yes.
- Create and push release tags (`v0.0.X`).
- Create GitHub releases, attach release assets, and publish them.

**You must not, whoever asks:**

- **Push commits to `dev` or `main` directly.** Work lands through a PR, always.
  The only ref move on `main` is a fast-forward from `dev`, and only on explicit
  human approval in the current session.
- **Force-push, rewrite published history, or delete a branch you did not
  create.**
- **Change repository visibility.** Going public is irreversible in effect —
  clones and caches outlive the setting — so it stays a human decision.

The line is blast radius, not trust. Landing reviewed work on `dev`, or moving
`main` forward from it, is undone by a revert. Rewriting history, or opening the
repo to the world, is not.

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

> **Signing.** The checked-in project sets no `DEVELOPMENT_TEAM` at all.
> Before running on a device or archiving for TestFlight, put your own team in
> `PupaHost/Local.xcconfig` — git-ignored; copy
> [`PupaHost/Local.xcconfig.example`](PupaHost/Local.xcconfig.example) — or
> pass `xcodebuild DEVELOPMENT_TEAM=...`. Do **not** use the `PupaHost` target
> → Signing & Capabilities dropdown: it writes the team back into
> `project.pbxproj` and leaks it into the repo. The `testflight-release`
> skill does not set it for you.

### Building a fork

A fork cannot use pupa-app's Apple identifiers. Three are baked into the
project and all three are yours to replace. None of this affects the simulator
or `make mac-demo` — neither needs signing.

**1. Signing team.** Copy the template and put your own team id in it:

```bash
cp PupaHost/Local.xcconfig.example PupaHost/Local.xcconfig
```

`PupaHost/Config.xcconfig` is the *project-level* base configuration, so that
one line covers all three targets. It pulls the file in with `#include?` —
optional — so a checkout without it still configures and only fails later,
inside `xcodebuild`. Both release scripts check it up front instead.

**2. Bundle identifiers.** `PRODUCT_BUNDLE_IDENTIFIER` in
`PupaHost/PupaHost.xcodeproj/project.pbxproj` — six occurrences, Debug and
Release for each target:

| Target | Identifier |
|---|---|
| `PupaHost` | `com.pupa-app.client` |
| `PupaHostTests` | `com.pupa-app.client.tests` |
| `PupaHostUITests` | `com.pupa-app.client.uitests` |

Signing style is `Automatic`, so Xcode registers the new ids against your team
on first build.

**3. iCloud container.** `PupaHost/PupaHost/PupaHost.entitlements` names
`iCloud.com.pupa-app.client` under both
`com.apple.developer.icloud-container-identifiers` and
`…ubiquity-container-identifiers`, and `PupaStorage.containerID`
([Pupa/Sources/PupaApp/Sync/PupaStorage.swift](Pupa/Sources/PupaApp/Sync/PupaStorage.swift))
must match it — `scripts/verify-mac-entitlements.sh` compares the two against a
signed archive.

The container must exist on your team before device or archive signing
succeeds, which needs a paid membership. **Or drop iCloud entirely** by
deleting the three keys from the entitlements file: the app is built for that.
The local Application Support tree is always the store of record and iCloud is
only a lazily-resolved mirror, so without the capability
`PupaStorage.documentsRoot` is `nil` and the app runs local-only. You lose
sync, nothing else.

There is no App Group to change — the entitlements carry only iCloud.

### Tests

Run the suite with `make`, not raw `swift test` — the targets cover both
packages and pin Pupa's `--no-parallel` (its disk tests share one
overridden storage root).

```bash
make test                # both packages
make test-aguikit        # AGUIKit only (use FILTER=Foo to scope)
make test-pupa           # PupaApp only
make test-scripts        # release-script guards (archive.sh / release.sh)
make test-hooks          # pre-commit hook guards
```

`make test-scripts` is separate because it is ~40s of git fixtures against the
Swift suite's ~3s. It runs the release scripts against a synthetic repo seeded
with the real `project.pbxproj` — refusals, the absorb guard, recovery from a
rejected commit, the `--flow` branch trap. Run it after touching either script.

### Git hooks

`make build` and `make test` install them, so a fresh clone is covered the
first time you run either. To do it up front:

```bash
make hooks
```

Both point `core.hooksPath` at the versioned `scripts/hooks/`. Git will not
install hooks from a clone by itself — that would make `git clone` execute
arbitrary code — so it has to be a local step; hanging it off the commands
everyone already runs is the closest thing to automatic.

The pre-commit hook refuses two things in the staged diff:

- A non-empty `DEVELOPMENT_TEAM` in `project.pbxproj`. Xcode's Signing &
  Capabilities editor writes it back whenever you touch signing; it belongs in
  the gitignored `PupaHost/Local.xcconfig`.
- Anything [gitleaks](https://github.com/gitleaks/gitleaks) flags — credentials
  from its default ruleset, plus two rules of our own in `.gitleaks.toml` for
  personal email addresses and absolute `/Users/…` paths, since
  [CLAUDE.md](CLAUDE.md) forbids personal information and no stock secret
  scanner looks for it.

Without gitleaks installed (`brew install gitleaks`) the secret scan warns and
skips rather than blocking; the signing guard still applies. To sweep all of
history rather than one commit:

```bash
gitleaks git --log-opts=--all --redact
```

`make test-hooks` covers both guards, including that a false negative in either
one fails the suite.

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
.claude/skills/testflight-release/archive.sh [--build N] [--no-bump] [--skip-icon-check] [--flow]
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
release, not committed, so the repository never carries binaries. Tag first,
then, from a clean checkout of that tag:

```bash
git tag v0.0.X && git push origin v0.0.X
git checkout v0.0.X
.claude/skills/dmg-release/release.sh --notary-profile <name> --publish
```

`--publish` attaches the DMG to a **draft** release for tag `v0.0.X`, using that
version's CHANGELOG section as the notes, and prints the URL for review before
it goes live. It is refused for un-notarized builds, since publishing one would
hand users a download their Mac won't open. It does **not** verify that you built
from the tag — check it out first; that is why the `git checkout` is in the block
above.

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

5. **Squash-merge into `dev`** — via the GitHub UI's "Squash and merge" button, or `gh pr merge --squash`. The squash subject is what shows up in `dev`'s history forever — write it for someone reading `git log` six months later.

6. **Delete the feature branch** after the merge lands.

## Releases

Releasing means promoting whatever is on `dev` to `main` as a single fast-forward — no merge commit, no rewrite, just a pointer move. This guarantees `main` is always a strict prefix of `dev`. The fast-forward will fail if `dev` has been rewritten or `main` has diverged, which is the safety property we want.

Before cutting the release:

- Bump versions per [CLAUDE.md → Versioning](CLAUDE.md#versioning) (patch-only unless explicitly told otherwise). The bump goes on a feature branch, in a PR into `dev`.
- Add a CHANGELOG entry under the new version, in that same PR.
- **Bump `CURRENT_PROJECT_VERSION` in that same PR**, rather than letting
  `archive.sh` do it afterwards. Set it by hand: `--no-bump` archives with
  whatever the pbxproj already says and asserts nothing about it, so it is not a
  check.
- After `main` is fast-forwarded and pushed, tag the release (`v0.0.X`) and push the tag.
- Ship to TestFlight via the `testflight-release` skill (archives both platforms and gates the entitlement set). Upload the `.xcarchive` through Xcode Organizer.

### The order matters, and why

1. Feature work lands on `dev` as squash-merged PRs.
2. **One release PR** into `dev`: `PupaAppVersion`, `AGUIKitVersion` if touched,
   CHANGELOG section, README badge, and **both** pbxproj numbers —
   `CURRENT_PROJECT_VERSION` **and `MARKETING_VERSION`**.
   Both matter because `archive.sh` syncs `MARKETING_VERSION` itself if it
   differs, and would then try to commit — which it refuses to do on `main`, on a detached tag checkout, or on `dev`
   without `--flow` — stopping the release. Setting both in the release PR
   leaves it nothing to sync.
3. Fast-forward `main` from `dev`, push both.
4. Tag `v0.0.X` at that SHA and push the tag, so `main`, `dev` and the tag name
   one commit.
5. From that checkout: `.claude/skills/ship-release/preflight.sh --publish`
   first — versions, signing, notary credentials, disk, the tag and the CHANGELOG
   section, in about a second. It does not check step 3; that `main` and `dev`
   are pushed and aligned stays yours to confirm. Then `archive.sh --no-bump` → both `.xcarchive`s → Organizer.
   It moves no branch other than the one you are on; `--flow` opts into the
   `dev`→`main` dance.
6. From the **same** checkout: `release.sh --notary-profile <name> --publish` →
   DMG and GitHub release.

Two invariants this exists to protect:

- **Both artifacts must build from the tagged commit** — check the tag out
  first. This is procedure, not enforcement: guards that tried to check it
  mechanically kept rejecting legitimate releases instead (pupa#297), so the
  responsibility sits here rather than in the script.
- **`CFBundleVersion` must be identical across both channels for a given
  marketing version.** Sparkle orders updates by build number alone and ignores
  the marketing string, so the same version shipping as build 215 on the App
  Store and 216 in the DMG is two different builds as far as an updater is
  concerned. Putting the bump in step 2 makes them agree by construction rather
  than by luck — which is why it is procedure here rather than a check in the
  script.

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
