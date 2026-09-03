---
name: ship-release
description: Use when shipping a Pupa release through both channels at once — "ship the release", "release both", "TestFlight and the DMG", "cut 0.0.X", "/ship-release". Covers the whole run: what to check before starting, which half goes first, and which steps a human has to take.
---

Run `preflight.sh` next to this file, then the two channel skills in the order
below. Do not re-implement either — `testflight-release` and `dmg-release` own
their own steps.

**Script path:** `.claude/skills/ship-release/preflight.sh`

## Order, and why it is not arbitrary

1. **`ship-release/preflight.sh --publish`** — one second, reports every blocker
   at once.
2. **`testflight-release`** → both `.xcarchive`s. First because it is the channel
   that reads and asserts the build number, and because Organizer upload is a
   human step that can run while the DMG builds.
3. **`dmg-release`** → notarized, stapled DMG, then the draft GitHub release.

Both channels must ship the **same `CFBundleVersion`**. Sparkle orders DMG
updates by build number alone and ignores the marketing string, so 0.0.279 as
build 237 on the App Store and 238 in the DMG is two different builds to the
updater. The numbers agree by construction when the release PR sets them — which
is what preflight checks — not by running the scripts in a lucky order.

## Preflight

```bash
.claude/skills/ship-release/preflight.sh --publish
```

Checks, all of which have failed late in a real release: `MARKETING_VERSION` vs
`PupaAppVersion`, `CURRENT_PROJECT_VERSION` vs commit count, `DEVELOPMENT_TEAM`,
the Developer ID certificate, that the notarytool profile authenticates, free
disk, the tag on origin, and a non-empty CHANGELOG section. Reports all failures
rather than stopping at the first. `--publish` adds the last two.

`PUPA_PREFLIGHT_OFFLINE=1` skips the notarytool round trip.

**A failed check is a stop, not a warning.** Fixing `MARKETING_VERSION` means a
PR into `dev` and a re-tag — cheap before the release, expensive mid-flight.

## The run

```bash
.claude/skills/testflight-release/archive.sh --no-bump
.claude/skills/dmg-release/release.sh --publish
```

`--no-bump` because the release PR already set the build number. Both read
`PupaAppVersion`; neither should have anything to commit. If `archive.sh` wants
to commit, preflight was skipped or ignored.

To finish a release whose build succeeded but whose upload did not, use
`release.sh --publish-only` — it attaches the DMG already in `build/` instead of
spending another archive and another notarization submission.

## Human-only steps

An assistant may run the scripts. It may not do these (`CONTRIBUTING.md` → AI
assistants), unless the user asks for them explicitly in the session:

| Step | Why |
|---|---|
| Fast-forward `main`, push `main`/`dev`, push the tag | Moving release branches |
| Upload each `.xcarchive` via Xcode Organizer | Needs App Store Connect credentials; deliberately not scripted |
| Flip the draft release to published | Public and permanent; `releases/latest` ignores drafts, so this is the moment the download changes |

Organizer only auto-lists archives under `~/Library/Developer/Xcode/Archives/`.
These are written to `build/`, so `archive.sh` opens them itself to register
them. **There is no prompt before that point** — an archive can succeed and
Organizer still look empty.

## What does not need doing

- **No `website` PR.** `website/src/pages/releases.astro` reads the GitHub
  releases API client-side, and the download links are
  `releases/latest/download/Pupa.dmg`. Both pick up a new release with no
  rebuild — which is why `release.sh` uploads under that constant asset name.
  Only a change to the *shape* of the release (asset name, extra artifacts)
  needs a website change.
- **No CHANGELOG or version bump here.** That is the release PR's job, before
  any of this starts.

## Failure modes worth recognising

- **`Nn G free — Nn G needed`**: the free-space guard. 12G before the two
  archives, and 8G checked again before the DMG once they are on disk — a floor
  at each step, not one total. Clear `~/Library/Developer/Xcode/iOS DeviceSupport`,
  `xcrun simctl delete unavailable`, or DerivedData — all regenerable. A disk
  that reaches zero mid-archive takes the rest of the session with it.
- **`archive.sh` refuses to commit**: `MARKETING_VERSION` drifted and the script
  is on `dev` or `main`. Land it in a PR; do not pass `--flow` to get around it.
- **A tool refuses `--publish`**: some harnesses gate the flag. Build without it,
  then `release.sh --publish-only`, or hand the command to the user. Never
  rebuild just to publish.
