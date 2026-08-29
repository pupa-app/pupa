---
name: testflight-release
description: Archive Pupa iOS + macOS for TestFlight upload (one Universal Purchase record, both ship together). Verifies the App Store icon is opaque, syncs MARKETING_VERSION to PupaAppVersion, bumps CURRENT_PROJECT_VERSION, runs xcodebuild archive for both platforms, checks the macOS entitlement set, and reports both .xcarchive paths so the user can upload via Xcode Organizer. Invoke when the user says "ship to TestFlight", "archive for TestFlight", "release ios", "distribute ios", or "/testflight-release".
---

> **Workflow note:** By default the script bumps and archives **the current branch in place** and moves no branches — run it from a clean checkout of the release tag. Passing `--flow` opts into the old behaviour: land the bump on `dev`, fast-forward `main` from it, then archive `main`. That path moves `main`, so it is human-only.

Run `archive.sh` next to this file. Do not re-implement its logic with sequential commands.

If you change `archive.sh`, run `make test-scripts` — the fixture suite in
`scripts/test-release-scripts.sh` exercises its refusals, the absorb guard, the
commit-failure recovery and the `--flow` branch trap against a synthetic repo.

**Script path:** `.claude/skills/testflight-release/archive.sh`

## When to use

User wants `.xcarchive`s ready for TestFlight upload. Typical phrasings: "ship to TestFlight", "archive for TestFlight", "make a build for TestFlight", "release the iOS app". Pupa ships iOS + macOS under one Universal Purchase App Store Connect record, so the script always archives both platforms from the single `PupaHost` target (`SUPPORTED_PLATFORMS` covers both — same `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, no per-platform version skew possible). The skill stops at producing the `.xcarchive`s — uploading is done manually via Xcode Organizer (avoids needing App Store Connect API credentials).

> **The `dev`→`main` dance is opt-in (`--flow`), and human-only.** By default the
> script bumps and archives the current branch in place, moving no branch ref
> other than the one you are already on. It still *commits* the bump there, but
> refuses to on `main`, on a detached HEAD, or on `dev` — so the bump can only
> land where a PR can carry it, which keeps an assistant inside the AI rules in
> `CONTRIBUTING.md`.
>
> Assistants should also pass `--no-bump` — but it does not stop the script
> committing: a `MARKETING_VERSION` sync sets `NEEDS_COMMIT` on its own, which is
> why the refusal is outright rather than conditional. Set `MARKETING_VERSION`
> and the build number in the release PR (`CONTRIBUTING.md` → Releases) so
> nothing is left to commit at archive time.

## Before invoking the script

1. **Confirm git state.** Under `--flow` the script bumps on `dev`, fast-forwards `main` from it, then archives `main`; by default it bumps and archives wherever you already are. Verify with the user:
   - With `--flow`: `dev` holds the release-ready commits and `main` can fast-forward from it. Without it (the default) only the current checkout matters.
   - Working tree should be clean (no uncommitted changes) so the archive matches a known git SHA. If dirty, ask whether to commit/stash first.

2. **Confirm what changed since the last successful TestFlight upload.** Specifically:
   - Has `PupaAppVersion` in `Pupa/Sources/PupaApp/Version.swift` changed? The script reads it and syncs `MARKETING_VERSION` automatically. It does **not** affect the build number — see below.

3. **Build number is automatic and monotonic.** `CURRENT_PROJECT_VERSION` defaults to the branch's commit count and **never resets**, not even on a marketing-version bump. Sparkle (the direct-download DMG channel) orders updates by `CFBundleVersion` alone and ignores the marketing string, so a reset reads as a downgrade and silently strands DMG users on the old build. App Store Connect only needs uniqueness within a marketing version, so monotonic satisfies both channels. `--build N` is for manual correction only and is rejected unless `N` exceeds the current build. See pupa#246.

## Invocation

```bash
.claude/skills/testflight-release/archive.sh [--build N] [--no-bump] [--skip-icon-check] [--flow]
```

| Flag | Meaning |
|---|---|
| `--build N` | Set `CURRENT_PROJECT_VERSION` explicitly; must exceed the current build (default: commit count) |
| `--no-bump` | Don't change the build number. Correct whenever the release PR already set it. |
| `--skip-icon-check` | Skip the `icon_1024.png` / `AppIcon.icon` integrity checks (don't use unless you know why) |
| `--flow` | Opt into switching to `dev`, committing there, and fast-forwarding `main` before archiving. Human-only. |

Branch names default to `dev`/`main`; override with `DEV_BRANCH=` / `MAIN_BRANCH=` env vars if needed.

## What the script does

1. With `--flow` only: switches to `dev` so the bump lands there first. Otherwise stays put.
2. Checks the icons: `icon_1024.png` has no alpha (App Store Connect silently shows the wireframe placeholder for icons with transparency), and `AppIcon.icon` still has its alpha-backed `mark.png` and `"glass": false`.
3. Reads `PupaAppVersion` from `Version.swift`, syncs `MARKETING_VERSION` in `project.pbxproj` if they differ.
4. Sets `CURRENT_PROJECT_VERSION` to the commit count (floored at current+1, so it can only ever rise) for the app target's buildSettings blocks only (matched by the app `MARKETING_VERSION`; test targets stay at `1`).
5. If pbxproj changed, commits on the current branch, with a subject naming what
   actually changed (build number, `MARKETING_VERSION`, or both). It decides
   whether a commit is needed *before* editing anything, and refuses — leaving the
   file untouched — on `main`, on a detached HEAD, on `dev` unless `--flow`, or if
   `project.pbxproj` already carries changes of the user's own. So by default the
   bump lands on a feature branch, which is the only place an assistant may put it.
   Stops if the working tree is otherwise dirty.
6. With `--flow` only: fast-forwards `main` from `dev` (`--ff-only`; aborts if diverged) and archives `main`. Otherwise archives the current checkout.
7. Runs `xcodebuild archive` twice: `-destination generic/platform=iOS` into `build/Pupa.xcarchive`, then `-destination generic/platform=macOS` into `build/Pupa-macOS.xcarchive`.
8. Checks the macOS archive's signed entitlements against the expected set (sandbox,
   network client + server, user-selected files). The signature is the only ground
   truth here — the `com.apple.security.*` keys are synthesized from `ENABLE_*` build
   settings and never appear in `PupaHost.entitlements`.
9. Reads each archive's `Info.plist` version + build + bundle ID, asserts they are present, and prints them. It does not compare them against `PupaAppVersion` — `dmg-release` does that for its own build.

Nothing is pushed. Under `--flow` the script prints the `git push origin dev main`
command for a human to run. By default the bump commit sits on your feature
branch — land it through a PR like any other change.

## After the script

1. Run `open build/Pupa.xcarchive build/Pupa-macOS.xcarchive` — this registers both archives with Xcode so they appear in Organizer. (Organizer only auto-lists archives from `~/Library/Developer/Xcode/Archives/`; the script writes to `build/` instead, so opening them manually is required.)

2. Report to the user:
   - Both archive paths: `build/Pupa.xcarchive`, `build/Pupa-macOS.xcarchive`
   - Verified version + build + bundle ID for each
   - The next manual step:

     > Open Xcode → **Window → Organizer** (⌥⇧⌘O). Both archives should now appear under the *Archives* tab. Select each in turn → **Distribute App** → *App Store Connect* → *Upload*. Wait ~10–30 min for Apple processing per platform, then check the **TestFlight** tab in App Store Connect — iOS and macOS builds list separately, but the same tester group covers both once each clears export compliance.
     >
     > If an archive doesn't appear, close and reopen Organizer.

3. **Only under `--flow`**, print this for the human to run — do not run it
   yourself. Moving `main` and pushing it are human-only under the AI rules in
   `CONTRIBUTING.md`:
   ```bash
   git push origin dev main
   ```
   Report the local SHAs so they can confirm both refs advanced together. By
   default the bump is a commit on your feature branch; land it through a PR
   rather than pushing a branch this script moved.

If the user wants to skip Organizer and upload via CLI: `xcrun altool --upload-app -f build/Pupa.xcarchive ...` needs an App-Specific Password or API key — out of scope for this skill.

## Failure modes to surface clearly

- **Icon has alpha**: tell the user the icon must be flattened. Suggest running our flatten one-liner (composite onto white, save back). Don't auto-flatten — icon edits are visual, the user should approve. This check is for the **master source art** `icon_1024.png` only. Two derived sets are *supposed* to have alpha: `mac_icon_*.png` (squircle mask + inset — `swift scripts/gen-macos-appicon.swift`) and `AppIcon.icon/Assets/mark.png` (transparent-backed mark — `swift scripts/gen-icon-mark.swift`). Regenerate both if the source art changes.
- **`AppIcon.icon` missing or `"glass": false` gone**: the shipped icon would revert to the system's auto-applied Liquid Glass, which visibly blurs the mark. Restore the key rather than skipping the check.
- **macOS entitlements drifted**: the gate prints a diff — `<` lines are keys we expect
  but the build lost (that feature is dead at runtime, as in pupa#229), `>` lines are keys
  the build gained that no code uses (review risk). Don't relax the expected set to make it
  pass; find the `ENABLE_*` build setting that moved. If the change is deliberate, update
  `EXPECTED_SECURITY` in `scripts/verify-mac-entitlements.sh` and the entitlement
  table in `docs/architecture.md` in the same commit.
- **Working tree dirty (non-pbxproj files)**: refuse and ask the user to commit/stash first.
- **Working tree dirty (`project.pbxproj` itself)**: allowed on arrival, but refused
  once a bump or `MARKETING_VERSION` sync is actually needed — `git add` stages the
  whole file, so the user's own edit would land in the bump commit.
  Ask them to commit or stash just that file.
- **`main` can't fast-forward from `dev`**: `main` has commits not on `dev` (they diverged). The script aborts before archiving. Resolve the branch state manually (or merge `main` into `dev`), then re-run. Under `--flow` the bump commit is already on `dev` at this point — no harm in re-running.
- **Archive fails on signing**: usually means agreements unaccepted at `developer.apple.com` or the Xcode Apple ID needs re-auth. Direct the user there; don't try to fix from the CLI.
- **`ITMS-` validation errors**: these only surface during upload (in Organizer), not archive. Out of scope for this skill — if Apple emails a rejection, address the specific error code.

## Don't

- Don't push *before* the archive succeeds and is verified. Under `--flow` the script moves branches *locally* only; the push is a human step afterwards. By default `main` and `dev` are untouched — the bump is a commit on your feature branch, for a PR.
- Don't force-push. `dev`→`main` is a fast-forward; if a plain push is rejected, the branches diverged — stop and surface it, never `--force`.
- Don't upload to App Store Connect from this skill — Organizer step is intentional (avoids credential handling).
- Don't touch `Version.swift` / `PupaAppVersion` — that bump is part of the project release flow (CHANGELOG), not this skill's job.
