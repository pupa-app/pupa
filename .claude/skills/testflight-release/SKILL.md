---
name: testflight-release
description: Archive Pupa iOS app for TestFlight upload. Verifies the App Store icon is opaque, syncs MARKETING_VERSION to PupaAppVersion, bumps CURRENT_PROJECT_VERSION, runs xcodebuild archive, and reports the .xcarchive path so the user can upload via Xcode Organizer. Invoke when the user says "ship to TestFlight", "archive for TestFlight", "release ios", "distribute ios", or "/testflight-release".
---

> **Workflow note:** Ideally the `project.pbxproj` build-number bump should be committed to `dev` *before* the `dev`→`main` fast-forward PR, so the bump is already part of main's history and the branches stay aligned. In practice: bump the build on dev, merge to main, *then* archive. If you forgot and the script commits the bump directly to main, immediately reset dev to main (see "After the script") so they share the same history.

Run `archive.sh` next to this file. Do not re-implement its logic with sequential commands.

**Script path:** `.claude/skills/testflight-release/archive.sh`

## When to use

User wants a `.xcarchive` ready for TestFlight upload. Typical phrasings: "ship to TestFlight", "archive for TestFlight", "make a build for TestFlight", "release the iOS app". The skill stops at producing the `.xcarchive` — uploading is done manually via Xcode Organizer (avoids needing App Store Connect API credentials).

## Before invoking the script

1. **Confirm git state.** The script archives whatever is in the working tree. Verify with the user:
   - On which branch should the archive be built? Usually `main` after a release fast-forward from `dev`. Confirm if unsure.
   - Working tree should be clean (no uncommitted changes) so the archive matches a known git SHA. If dirty, ask whether to commit/stash first.

2. **Confirm what changed since the last successful TestFlight upload.** Specifically:
   - Has `PupaAppVersion` in `Pupa/Sources/PupaApp/Version.swift` changed? If yes, this is a new MARKETING_VERSION and the build number can reset to `1`. If no, it's a re-upload of the same version and the build number must be unique (current+1).
   - The script will read `PupaAppVersion` and sync `MARKETING_VERSION` automatically.

3. **Decide build number behavior**: by default, the script bumps `CURRENT_PROJECT_VERSION` by `1`. Pass `--build N` to set an explicit value (e.g. reset to `1` after a marketing-version bump).

## Invocation

```bash
.claude/skills/testflight-release/archive.sh [--build N] [--no-bump] [--skip-icon-check]
```

| Flag | Meaning |
|---|---|
| `--build N` | Set `CURRENT_PROJECT_VERSION` explicitly (default: current + 1) |
| `--no-bump` | Don't change the build number at all (rare — only for local validation builds) |
| `--skip-icon-check` | Skip the alpha-channel check on `icon_1024.png` (don't use unless you know why) |

## What the script does

1. Reads `PupaAppVersion` from `Version.swift`, syncs `MARKETING_VERSION` in `project.pbxproj` if they differ.
2. Bumps `CURRENT_PROJECT_VERSION` for the `pupa.PupaHost` target only (test targets stay at `1`).
3. Checks that `icon_1024.png` has no alpha channel — fails loudly if it does (App Store Connect silently shows the wireframe placeholder for icons with transparency).
4. If pbxproj changed, commits the bump with a generic `chore(ios): bump build to N` message. Stops if working tree is otherwise dirty.
5. Runs `xcodebuild archive` into `build/Pupa.xcarchive`.
6. Verifies the produced archive's `Info.plist` reports the expected version + build + bundle ID.

## After the script

1. Run `open build/Pupa.xcarchive` — this registers the archive with Xcode so it appears in Organizer. (Organizer only auto-lists archives from `~/Library/Developer/Xcode/Archives/`; the script writes to `build/` instead, so opening it manually is required.)

2. Report to the user:
   - The archive path: `build/Pupa.xcarchive`
   - Verified version + build + bundle ID
   - The next manual step:

     > Open Xcode → **Window → Organizer** (⌥⇧⌘O). The archive should now appear under the *Archives* tab. Select it → **Distribute App** → *App Store Connect* → *Upload*. Wait ~10–30 min for Apple processing, then check the **TestFlight** tab in App Store Connect.
     >
     > If the archive still doesn't appear, close and reopen Organizer.

3. **Align dev with main.** The script may have committed the build bump directly to `main`. Push main, then reset `dev` to match so the branches share the same history:
   ```bash
   git push origin main
   git checkout dev
   git reset --hard main
   git push --force-with-lease origin dev
   ```

If the user wants to skip Organizer and upload via CLI: `xcrun altool --upload-app -f build/Pupa.xcarchive ...` needs an App-Specific Password or API key — out of scope for this skill.

## Failure modes to surface clearly

- **Icon has alpha**: tell the user the icon must be flattened. Suggest running our flatten one-liner (composite onto white, save back). Don't auto-flatten — icon edits are visual, the user should approve.
- **Working tree dirty (non-pbxproj files)**: refuse and ask the user to commit/stash first.
- **Archive fails on signing**: usually means agreements unaccepted at `developer.apple.com` or the Xcode Apple ID needs re-auth. Direct the user there; don't try to fix from the CLI.
- **`ITMS-` validation errors**: these only surface during upload (in Organizer), not archive. Out of scope for this skill — if Apple emails a rejection, address the specific error code.

## Don't

- Don't push to `main` or `dev` from this skill — git flow is the user's call.
- Don't upload to App Store Connect from this skill — Organizer step is intentional (avoids credential handling).
- Don't touch `Version.swift` / `PupaAppVersion` — that bump is part of the project release flow (CHANGELOG), not this skill's job.
