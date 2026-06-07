---
name: testflight-release
description: Archive Pupa iOS app for TestFlight upload. Verifies the App Store icon is opaque, syncs MARKETING_VERSION to PupaAppVersion, bumps CURRENT_PROJECT_VERSION, runs xcodebuild archive, and reports the .xcarchive path so the user can upload via Xcode Organizer. Invoke when the user says "ship to TestFlight", "archive for TestFlight", "release ios", "distribute ios", or "/testflight-release".
---

> **Workflow note:** The script lands the build-number bump on `dev`, then fast-forwards `main` from `dev`, then archives `main`. So the bump is part of `dev`'s history *before* it reaches `main`, and the branches stay aligned — no post-hoc realign. You don't need to be on any particular branch first; the script switches to `dev` itself. (Use `--no-flow` to bump+archive the current branch in place, skipping the dev→main dance — for local validation builds only.)

Run `archive.sh` next to this file. Do not re-implement its logic with sequential commands.

**Script path:** `.claude/skills/testflight-release/archive.sh`

## When to use

User wants a `.xcarchive` ready for TestFlight upload. Typical phrasings: "ship to TestFlight", "archive for TestFlight", "make a build for TestFlight", "release the iOS app". The skill stops at producing the `.xcarchive` — uploading is done manually via Xcode Organizer (avoids needing App Store Connect API credentials).

## Before invoking the script

1. **Confirm git state.** The script bumps on `dev`, fast-forwards `main` from `dev`, then archives `main`. Verify with the user:
   - `dev` holds the release-ready commits (features merged, `Version.swift`/CHANGELOG bumped). The script fast-forwards `main` from it — if `main` has commits not on `dev`, the FF aborts and the script stops.
   - Working tree should be clean (no uncommitted changes) so the archive matches a known git SHA. If dirty, ask whether to commit/stash first.

2. **Confirm what changed since the last successful TestFlight upload.** Specifically:
   - Has `PupaAppVersion` in `Pupa/Sources/PupaApp/Version.swift` changed? If yes, this is a new MARKETING_VERSION and the build number can reset to `1`. If no, it's a re-upload of the same version and the build number must be unique (current+1).
   - The script will read `PupaAppVersion` and sync `MARKETING_VERSION` automatically.

3. **Decide build number behavior**: by default, the script bumps `CURRENT_PROJECT_VERSION` by `1`. Pass `--build N` to set an explicit value (e.g. reset to `1` after a marketing-version bump).

## Invocation

```bash
.claude/skills/testflight-release/archive.sh [--build N] [--no-bump] [--skip-icon-check] [--no-flow]
```

| Flag | Meaning |
|---|---|
| `--build N` | Set `CURRENT_PROJECT_VERSION` explicitly (default: current + 1) |
| `--no-bump` | Don't change the build number at all (rare — only for local validation builds) |
| `--skip-icon-check` | Skip the alpha-channel check on `icon_1024.png` (don't use unless you know why) |
| `--no-flow` | Bump + archive the current branch in place; skip the `dev`→`main` fast-forward (local validation builds) |

Branch names default to `dev`/`main`; override with `DEV_BRANCH=` / `MAIN_BRANCH=` env vars if needed.

## What the script does

1. Switches to `dev` (unless `--no-flow`) so the bump lands there first.
2. Checks that `icon_1024.png` has no alpha channel — fails loudly if it does (App Store Connect silently shows the wireframe placeholder for icons with transparency).
3. Reads `PupaAppVersion` from `Version.swift`, syncs `MARKETING_VERSION` in `project.pbxproj` if they differ.
4. Bumps `CURRENT_PROJECT_VERSION` for the app target's buildSettings blocks only (matched by the app `MARKETING_VERSION`; test targets stay at `1`).
5. If pbxproj changed, commits the bump on `dev` with a generic `chore(ios): bump build to N` message. Stops if working tree is otherwise dirty.
6. Fast-forwards `main` from `dev` (`--ff-only`; aborts if diverged), then archives `main`.
7. Runs `xcodebuild archive` into `build/Pupa.xcarchive`.
8. Verifies the produced archive's `Info.plist` reports the expected version + build + bundle ID.

Nothing is pushed — both branches are aligned locally and the script prints the `git push origin dev main` command for you to run.

## After the script

1. Run `open build/Pupa.xcarchive` — this registers the archive with Xcode so it appears in Organizer. (Organizer only auto-lists archives from `~/Library/Developer/Xcode/Archives/`; the script writes to `build/` instead, so opening it manually is required.)

2. Report to the user:
   - The archive path: `build/Pupa.xcarchive`
   - Verified version + build + bundle ID
   - The next manual step:

     > Open Xcode → **Window → Organizer** (⌥⇧⌘O). The archive should now appear under the *Archives* tab. Select it → **Distribute App** → *App Store Connect* → *Upload*. Wait ~10–30 min for Apple processing, then check the **TestFlight** tab in App Store Connect.
     >
     > If the archive still doesn't appear, close and reopen Organizer.

3. **Push both branches.** The script bumped `dev` and fast-forwarded `main` from it, so they share the same history (no realign needed). Push both — a plain fast-forward push, no `--force`:
   ```bash
   git push origin dev main
   ```

If the user wants to skip Organizer and upload via CLI: `xcrun altool --upload-app -f build/Pupa.xcarchive ...` needs an App-Specific Password or API key — out of scope for this skill.

## Failure modes to surface clearly

- **Icon has alpha**: tell the user the icon must be flattened. Suggest running our flatten one-liner (composite onto white, save back). Don't auto-flatten — icon edits are visual, the user should approve.
- **Working tree dirty (non-pbxproj files)**: refuse and ask the user to commit/stash first.
- **`main` can't fast-forward from `dev`**: `main` has commits not on `dev` (they diverged). The script aborts before archiving. Resolve the branch state manually (or merge `main` into `dev`), then re-run. The bump commit is already on `dev` at this point — no harm in re-running.
- **Archive fails on signing**: usually means agreements unaccepted at `developer.apple.com` or the Xcode Apple ID needs re-auth. Direct the user there; don't try to fix from the CLI.
- **`ITMS-` validation errors**: these only surface during upload (in Organizer), not archive. Out of scope for this skill — if Apple emails a rejection, address the specific error code.

## Don't

- Don't push to `main` or `dev` from this skill — the script only moves branches *locally* (bump on `dev`, fast-forward `main`); pushing stays the user's call.
- Don't upload to App Store Connect from this skill — Organizer step is intentional (avoids credential handling).
- Don't touch `Version.swift` / `PupaAppVersion` — that bump is part of the project release flow (CHANGELOG), not this skill's job.
