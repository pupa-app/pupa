---
name: testflight-release
description: Archive Pupa iOS + macOS for TestFlight upload (one Universal Purchase record, both ship together). Verifies the App Store icon is opaque, syncs MARKETING_VERSION to PupaAppVersion, bumps CURRENT_PROJECT_VERSION, runs xcodebuild archive for both platforms, checks the macOS entitlement set, and reports both .xcarchive paths so the user can upload via Xcode Organizer. Invoke when the user says "ship to TestFlight", "archive for TestFlight", "release ios", "distribute ios", or "/testflight-release".
---

> **Workflow note:** The script lands the build-number bump on `dev`, then fast-forwards `main` from `dev`, then archives `main`. So the bump is part of `dev`'s history *before* it reaches `main`, and the branches stay aligned — no post-hoc realign. You don't need to be on any particular branch first; the script switches to `dev` itself. (Use `--no-flow` to bump+archive the current branch in place, skipping the dev→main dance — for local validation builds only.)

Run `archive.sh` next to this file. Do not re-implement its logic with sequential commands.

**Script path:** `.claude/skills/testflight-release/archive.sh`

## When to use

User wants `.xcarchive`s ready for TestFlight upload. Typical phrasings: "ship to TestFlight", "archive for TestFlight", "make a build for TestFlight", "release the iOS app". Pupa ships iOS + macOS under one Universal Purchase App Store Connect record, so the script always archives both platforms from the single `PupaHost` target (`SUPPORTED_PLATFORMS` covers both — same `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, no per-platform version skew possible). The skill stops at producing the `.xcarchive`s — uploading is done manually via Xcode Organizer (avoids needing App Store Connect API credentials).

> **Assistants must pass `--no-flow`.** Without it the script commits a build
> bump straight onto `dev` and fast-forwards `main` — both forbidden by the AI
> rules in `CONTRIBUTING.md`. With `--no-flow` it bumps and archives the current
> branch in place, which is safe. Branch movement, tagging `main`, and pushing
> are the human's steps.

## Before invoking the script

1. **Confirm git state.** The script bumps on `dev`, fast-forwards `main` from `dev`, then archives `main`. Verify with the user:
   - `dev` holds the release-ready commits (features merged, `Version.swift`/CHANGELOG bumped). The script fast-forwards `main` from it — if `main` has commits not on `dev`, the FF aborts and the script stops.
   - Working tree should be clean (no uncommitted changes) so the archive matches a known git SHA. If dirty, ask whether to commit/stash first.

2. **Confirm what changed since the last successful TestFlight upload.** Specifically:
   - Has `PupaAppVersion` in `Pupa/Sources/PupaApp/Version.swift` changed? The script reads it and syncs `MARKETING_VERSION` automatically. It does **not** affect the build number — see below.

3. **Build number is automatic and monotonic.** `CURRENT_PROJECT_VERSION` defaults to the branch's commit count and **never resets**, not even on a marketing-version bump. Sparkle (the direct-download DMG channel) orders updates by `CFBundleVersion` alone and ignores the marketing string, so a reset reads as a downgrade and silently strands DMG users on the old build. App Store Connect only needs uniqueness within a marketing version, so monotonic satisfies both channels. `--build N` is for manual correction only and is rejected unless `N` exceeds the current build. See pupa#246.

## Invocation

```bash
.claude/skills/testflight-release/archive.sh [--build N] [--no-bump] [--skip-icon-check] [--no-flow]
```

| Flag | Meaning |
|---|---|
| `--build N` | Set `CURRENT_PROJECT_VERSION` explicitly; must exceed the current build (default: commit count) |
| `--no-bump` | Don't change the build number at all (rare — only for local validation builds) |
| `--skip-icon-check` | Skip the `icon_1024.png` / `AppIcon.icon` integrity checks (don't use unless you know why) |
| `--no-flow` | Bump + archive the current branch in place; skip the `dev`→`main` fast-forward (local validation builds) |

Branch names default to `dev`/`main`; override with `DEV_BRANCH=` / `MAIN_BRANCH=` env vars if needed.

## What the script does

1. Switches to `dev` (unless `--no-flow`) so the bump lands there first.
2. Checks the icons: `icon_1024.png` has no alpha (App Store Connect silently shows the wireframe placeholder for icons with transparency), and `AppIcon.icon` still has its alpha-backed `mark.png` and `"glass": false`.
3. Reads `PupaAppVersion` from `Version.swift`, syncs `MARKETING_VERSION` in `project.pbxproj` if they differ.
4. Sets `CURRENT_PROJECT_VERSION` to the commit count (floored at current+1, so it can only ever rise) for the app target's buildSettings blocks only (matched by the app `MARKETING_VERSION`; test targets stay at `1`).
5. If pbxproj changed, commits the bump on `dev` with a generic `chore(ios): bump build to N` message. Stops if working tree is otherwise dirty.
6. Fast-forwards `main` from `dev` (`--ff-only`; aborts if diverged), then archives `main`.
7. Runs `xcodebuild archive` twice: `-destination generic/platform=iOS` into `build/Pupa.xcarchive`, then `-destination generic/platform=macOS` into `build/Pupa-macOS.xcarchive`.
8. Checks the macOS archive's signed entitlements against the expected set (sandbox,
   network client + server, user-selected files). The signature is the only ground
   truth here — the `com.apple.security.*` keys are synthesized from `ENABLE_*` build
   settings and never appear in `PupaHost.entitlements`.
9. Verifies each archive's `Info.plist` reports the expected version + build + bundle ID.

Nothing is pushed — both branches are aligned locally and the script prints the `git push origin dev main` command for you to run.

## After the script

1. Run `open build/Pupa.xcarchive build/Pupa-macOS.xcarchive` — this registers both archives with Xcode so they appear in Organizer. (Organizer only auto-lists archives from `~/Library/Developer/Xcode/Archives/`; the script writes to `build/` instead, so opening them manually is required.)

2. Report to the user:
   - Both archive paths: `build/Pupa.xcarchive`, `build/Pupa-macOS.xcarchive`
   - Verified version + build + bundle ID for each
   - The next manual step:

     > Open Xcode → **Window → Organizer** (⌥⇧⌘O). Both archives should now appear under the *Archives* tab. Select each in turn → **Distribute App** → *App Store Connect* → *Upload*. Wait ~10–30 min for Apple processing per platform, then check the **TestFlight** tab in App Store Connect — iOS and macOS builds list separately, but the same tester group covers both once each clears export compliance.
     >
     > If an archive doesn't appear, close and reopen Organizer.

3. **Print this for the human to run — do not run it yourself.** Moving `main`
   and pushing it are human-only under the AI rules in `CONTRIBUTING.md`:
   ```bash
   git push origin dev main
   ```
   Report the local SHAs so they can confirm both refs advanced together.

If the user wants to skip Organizer and upload via CLI: `xcrun altool --upload-app -f build/Pupa.xcarchive ...` needs an App-Specific Password or API key — out of scope for this skill.

## Failure modes to surface clearly

- **Icon has alpha**: tell the user the icon must be flattened. Suggest running our flatten one-liner (composite onto white, save back). Don't auto-flatten — icon edits are visual, the user should approve. This check is for the **master source art** `icon_1024.png` only. Two derived sets are *supposed* to have alpha: `mac_icon_*.png` (squircle mask + inset — `swift scripts/gen-macos-appicon.swift`) and `AppIcon.icon/Assets/mark.png` (transparent-backed mark — `swift scripts/gen-icon-mark.swift`). Regenerate both if the source art changes.
- **`AppIcon.icon` missing or `"glass": false` gone**: the shipped icon would revert to the system's auto-applied Liquid Glass, which visibly blurs the mark. Restore the key rather than skipping the check.
- **macOS entitlements drifted**: the gate prints a diff — `<` lines are keys we expect
  but the build lost (that feature is dead at runtime, as in pupa#229), `>` lines are keys
  the build gained that no code uses (review risk). Don't relax the expected set to make it
  pass; find the `ENABLE_*` build setting that moved. If the change is deliberate, update
  `MACOS_ENTITLEMENTS_EXPECTED` here and the entitlement table in `docs/architecture.md`
  in the same commit.
- **Working tree dirty (non-pbxproj files)**: refuse and ask the user to commit/stash first.
- **`main` can't fast-forward from `dev`**: `main` has commits not on `dev` (they diverged). The script aborts before archiving. Resolve the branch state manually (or merge `main` into `dev`), then re-run. The bump commit is already on `dev` at this point — no harm in re-running.
- **Archive fails on signing**: usually means agreements unaccepted at `developer.apple.com` or the Xcode Apple ID needs re-auth. Direct the user there; don't try to fix from the CLI.
- **`ITMS-` validation errors**: these only surface during upload (in Organizer), not archive. Out of scope for this skill — if Apple emails a rejection, address the specific error code.

## Don't

- Don't push *before* the archive succeeds and is verified. The script only moves branches *locally* (bump on `dev`, fast-forward `main`); the push is the final step and happens only after every other step worked.
- Don't force-push. `dev`→`main` is a fast-forward; if a plain push is rejected, the branches diverged — stop and surface it, never `--force`.
- Don't upload to App Store Connect from this skill — Organizer step is intentional (avoids credential handling).
- Don't touch `Version.swift` / `PupaAppVersion` — that bump is part of the project release flow (CHANGELOG), not this skill's job.
