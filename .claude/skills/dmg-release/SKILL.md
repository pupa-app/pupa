---
name: dmg-release
description: Build a notarized, stapled Pupa.dmg signed with Developer ID — the download-from-the-website channel, alongside the App Store channel that testflight-release feeds. Archives macOS, exports with Developer ID, verifies the entitlement set and the embedded provisioning profile, packages the DMG, submits to notarytool and staples the ticket. Invoke when the user says "build the DMG", "notarize the Mac app", "ship the direct download", or "/dmg-release".
---

Run `release.sh` next to this file. Do not re-implement its steps by hand.

**Script path:** `.claude/skills/dmg-release/release.sh`

## When to use

The user wants the **direct-download** Mac build: a `.dmg` any Mac will open
without Gatekeeper complaining. The App Store channel is a different skill
(`testflight-release`) and a different signing identity.

Both channels come from the same target, bundle id, sandbox container and iCloud
container — that is deliberate, so a user who moves between them keeps their
data (pupa#246). Only the signing identity, the embedded provisioning profile,
and the update mechanism differ.

## One-time setup (the user must do this — it needs Account Holder access)

The script refuses to run until all three exist:

1. **Developer ID Application certificate** — developer.apple.com → Certificates.
   Not the same as the Apple Development cert used for TestFlight. Apple caps
   these at 5 per account and replacing one is painful, so back the private key
   up.
2. **A Developer ID provisioning profile for `com.pupa-app.pupa` that includes
   the iCloud container.** iCloud is a *restricted* entitlement: without a
   profile embedded in the app, the build launches normally and then never
   syncs, silently. The script checks for this and fails rather than shipping it.
3. **notarytool credentials**, stored once:
   ```bash
   xcrun notarytool store-credentials
   ```
   Pass the profile name via `--notary-profile` or `NOTARY_PROFILE`.

`PupaHost/Local.xcconfig` must also hold `DEVELOPMENT_TEAM` — same file the
Xcode build already uses.

## Invocation

```bash
.claude/skills/dmg-release/release.sh --notary-profile <name>
.claude/skills/dmg-release/release.sh --skip-notarize     # local validation only
```

| Flag | Meaning |
|---|---|
| `--notary-profile NAME` | notarytool keychain profile (or set `NOTARY_PROFILE`) |
| `--skip-notarize` | Archive, export and package only. The DMG is signed but **not** notarized, so Gatekeeper refuses it on every machine but this one. Never publish that output. |
| `--development-signing` | Smoke-test the pipeline with an Apple Development identity, for contributors with no Developer ID certificate. Implies `--skip-notarize` — Apple only notarizes Developer ID signatures — and names the output `…-dev-signed-DO-NOT-DISTRIBUTE.dmg`. |

Building a `--development-signing` DMG claims nothing and blocks nothing: a
later release under any Developer ID, on any team, is an independent signature
and an independent notarization submission. Delete the output when done.

## What the script does

1. Checks preconditions: Developer ID cert present, team id readable, notarytool
   credentials supplied.
2. Reads `PupaAppVersion` to name the DMG. It does **not** bump anything —
   version bumps are the project release flow's job, not this skill's.
3. Archives macOS Release.
4. Exports with `method: developer-id`, using an `ExportOptions.plist`
   **generated at runtime** into `build/`. It carries the team id, so it is never
   committed — the same reason `DEVELOPMENT_TEAM` lives in the git-ignored
   `Local.xcconfig`.
5. Runs `scripts/verify-mac-entitlements.sh --require-embedded-profile` — shared
   with `testflight-release`, so the two channels cannot drift apart on the
   sandbox keys or the iCloud container.
6. Confirms the signature verifies and the hardened runtime flag is set
   (notarization rejects builds without it).
7. Packages a DMG containing `Pupa.app` and an `/Applications` symlink.
8. Submits the **DMG** to notarytool and waits, then staples the ticket to it.
   The DMG rather than the app, so the ticket travels with the file users
   download and Gatekeeper is satisfied offline on first launch.
9. Validates the staple and confirms `spctl` accepts it — the same verdict a
   user's Mac will compute.

## Failure modes to surface clearly

- **No Developer ID Application certificate**: the user has to create it; it
  cannot be scripted. Point at developer.apple.com → Certificates and note it
  needs Account Holder access.
- **`verify-mac-entitlements.sh` reports a missing iCloud container key**: on
  this channel that almost always means no provisioning profile was embedded.
  Fix the profile rather than relaxing the check — shipping past it produces an
  app that silently never syncs.
- **Notarization rejected**: get the reason, don't guess.
  ```bash
  xcrun notarytool history --keychain-profile <name>
  xcrun notarytool log <submission-id> --keychain-profile <name>
  ```
  Common causes: a nested binary missing the hardened runtime, or an unsigned
  helper inside a framework.
- **`spctl` rejects the stapled DMG**: do not publish it. Gatekeeper will refuse
  it for every user.

## A note on shell hazards in this script

Every capability check is written as *capture, then test* — never
`cmd | grep -q`. Under `set -o pipefail` that idiom is a trap: `grep -q` exits
at the first match, the producer takes SIGPIPE, and the pipeline reports failure
even though the match succeeded. It only bites when the producer is still
writing, so it passes on short output and fails on long — the hardened-runtime
check failed exactly this way the first time the pipeline ran end to end. Keep
new checks in the same shape.

## Don't

- Don't publish a `--skip-notarize` build. It works only on the machine that
  built it.
- Don't commit `ExportOptions-developer-id.plist` — it carries the team id and
  the script regenerates it every run. `build/` is git-ignored.
- Don't bump versions here. That is the project release flow (CHANGELOG +
  `Version.swift`).
- Don't reuse the TestFlight archive. It is signed for the App Store and cannot
  be re-signed into a Developer ID build by this script.
