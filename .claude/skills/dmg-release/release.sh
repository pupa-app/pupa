#!/usr/bin/env bash
#
# dmg-release / release.sh
#
# Produce a notarized, stapled Pupa.dmg signed with Developer ID — the
# download-from-the-website channel, alongside the App Store one that
# testflight-release feeds. See SKILL.md next to this file.
#
# Same build shape as the App Store channel by design (same target, bundle id,
# sandbox container, iCloud container). Only the signing identity, the embedded
# provisioning profile, and the update mechanism differ. See pupa#246.
set -euo pipefail

PBXPROJ="PupaHost/PupaHost.xcodeproj/project.pbxproj"
VERSION_SWIFT="Pupa/Sources/PupaApp/Version.swift"
LOCAL_XCCONFIG="PupaHost/Local.xcconfig"
SCHEME="PupaHost"
PROJECT="PupaHost/PupaHost.xcodeproj"
ARCHIVE="build/Pupa-DeveloperID.xcarchive"
EXPORT_DIR="build/developer-id"
STAGE="build/dmg-stage"

NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SKIP_NOTARIZE=0
DEV_SIGNING=0
PUBLISH=0
usage() {
  cat <<EOF
usage: $0 [--notary-profile NAME] [--skip-notarize] [--development-signing]
  --notary-profile NAME  notarytool keychain profile (or set NOTARY_PROFILE).
                         Create once with: xcrun notarytool store-credentials
  --skip-notarize        Archive, export and package only. The DMG will be
                         signed but NOT notarized — Gatekeeper will refuse it on
                         any other Mac. Local validation only.
  --publish              After notarizing, attach the DMG to a DRAFT GitHub
                         release on tag v<version> and print its URL. The tag
                         must already exist on origin — tagging is a human step
                         (see CONTRIBUTING). The release is left as a draft for a
                         human to publish. Refused for un-notarized builds.
  --development-signing  Smoke-test this pipeline with an Apple Development
                         identity, for contributors with no Developer ID
                         certificate. Implies --skip-notarize (an Apple
                         Development signature cannot be notarized) and names
                         the output so it can never be mistaken for a release.
                         NOT DISTRIBUTABLE.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notary-profile) NOTARY_PROFILE="${2:-}"; shift 2;;
    --skip-notarize) SKIP_NOTARIZE=1; shift;;
    --development-signing) DEV_SIGNING=1; SKIP_NOTARIZE=1; shift;;
    --publish) PUBLISH=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
note() { echo "→ $*"; }

# --- preconditions --------------------------------------------------------
[[ -f "$PBXPROJ" ]] || die "Run from repo root. Could not find $PBXPROJ."
command -v xcodebuild >/dev/null || die "xcodebuild not on PATH."

# Read the identity list once. Note the shape of every check below: capture,
# then test. `cmd | grep -q` is unsafe under `set -o pipefail` — grep exits at
# the first match, cmd takes SIGPIPE, and the pipeline reports failure even
# though the match succeeded. It bites only when the producer is still writing,
# so it passes on small output and fails on large.
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)

# Developer ID is a different certificate from the Apple Development one used
# for TestFlight. Without it the export silently falls back and Gatekeeper
# rejects the result on every machine but this one.
if [[ $DEV_SIGNING -eq 1 ]]; then
  [[ "$IDENTITIES" == *"Apple Development"* ]] \
    || die "No 'Apple Development' identity in the keychain — nothing to sign the smoke test with."
  note "DEVELOPMENT SIGNING — exercising the pipeline, not producing a release"
else
  [[ "$IDENTITIES" == *"Developer ID Application"* ]] \
    || die "No 'Developer ID Application' certificate in the keychain.
       Create one at developer.apple.com → Certificates (Account Holder only; Apple caps
       these at 5 per account, so back the private key up). An Apple Development cert
       will not do — it is not trusted off this machine.
       To smoke-test this script without one, pass --development-signing."
fi

[[ -f "$LOCAL_XCCONFIG" ]] || die "Missing $LOCAL_XCCONFIG (git-ignored). It must hold: DEVELOPMENT_TEAM = <your team id>"
TEAM=$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' "$LOCAL_XCCONFIG" | sed -E 's/.*=[[:space:]]*([A-Za-z0-9]+).*/\1/' || true)
[[ -n "$TEAM" ]] || die "Could not read DEVELOPMENT_TEAM from $LOCAL_XCCONFIG."

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  [[ -n "$NOTARY_PROFILE" ]] || die "Pass --notary-profile NAME (or set NOTARY_PROFILE), or use --skip-notarize.
       Store credentials once with:  xcrun notarytool store-credentials"
  xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found. Needs Xcode 13+."
fi

# A DMG that isn't notarized is refused by Gatekeeper on every machine but the
# one that built it. Publishing one would hand users a download that cannot be
# opened, so the two flags are mutually exclusive rather than merely unwise.
if [[ $PUBLISH -eq 1 ]]; then
  [[ $SKIP_NOTARIZE -eq 0 ]] \
    || die "--publish cannot be combined with --skip-notarize or --development-signing.
       Only a notarized, stapled DMG may be published."
  command -v gh >/dev/null || die "gh not on PATH — needed for --publish."
fi

VERSION=$(grep 'PupaAppVersion: String' "$VERSION_SWIFT" | sed -E 's/.*"([^"]+)".*/\1/' || true)
[[ -n "$VERSION" ]] || die "Could not read PupaAppVersion from $VERSION_SWIFT."
if [[ $DEV_SIGNING -eq 1 ]]; then
  DMG="build/Pupa-$VERSION-dev-signed-DO-NOT-DISTRIBUTE.dmg"
  EXPORT_METHOD="development"
else
  DMG="build/Pupa-$VERSION.dmg"
  EXPORT_METHOD="developer-id"
fi
if [[ $PUBLISH -eq 1 ]]; then
  # All of these check before the 5-minute archive rather than after it.
  git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1 \
    || die "Tag v$VERSION does not exist on origin. Tag the release first:
       git tag v$VERSION && git push origin v$VERSION"

  # The archive is built from the working tree, so without these two checks a DMG
  # built from uncommitted edits — or from a different commit entirely — can be
  # published under a release tag with nothing to reveal it.
  [[ -z "$(git status --porcelain)" ]] \
    || die "Working tree is dirty. A published artifact must be reproducible from its tag."
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "v$VERSION^{commit}")" ]] \
    || die "HEAD is not the commit tagged v$VERSION.
       Check out the tag before publishing, or the release would ship a build nobody can reproduce."

  # Notes come from the CHANGELOG, and an empty section would publish blank notes.
  # Checked here so it fails in seconds rather than after notarization is spent.
  [[ -n "$(awk -v v="## [$VERSION]" '
      index($0, v) == 1 { inside = 1; next }
      inside && /^## \[/ { exit }
      inside { print }
    ' CHANGELOG.md | tr -d '[:space:]')" ]] \
    || die "CHANGELOG has no non-empty section for $VERSION — write one before publishing."
fi

note "building Pupa $VERSION for the Developer ID channel"

# project.pbxproj carries whatever MARKETING_VERSION the last TestFlight release
# left behind — archive.sh syncs it from PupaAppVersion at release time, and this
# script must not mutate a tracked file just to build. Override on the command
# line instead, or the DMG advertises a stale version in Finder, in Get Info, and
# to any updater that reads CFBundleShortVersionString.

# --- archive --------------------------------------------------------------
mkdir -p build
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGE"
note "archiving macOS (3–5 min)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" \
  archive \
  >/tmp/pupa-dmg-archive.log 2>&1 \
  || { tail -40 /tmp/pupa-dmg-archive.log >&2; die "xcodebuild archive failed. Full log: /tmp/pupa-dmg-archive.log"; }

# --- export with Developer ID ---------------------------------------------
# Generated at runtime rather than committed: it carries the team id, which
# must never land in the repo (same reason DEVELOPMENT_TEAM lives in the
# git-ignored Local.xcconfig).
EXPORT_PLIST="build/ExportOptions-developer-id.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$EXPORT_METHOD</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST

note "exporting ($EXPORT_METHOD)..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates \
  >/tmp/pupa-dmg-export.log 2>&1 \
  || { tail -40 /tmp/pupa-dmg-export.log >&2; die "xcodebuild -exportArchive failed. Full log: /tmp/pupa-dmg-export.log"; }

APP="$EXPORT_DIR/PupaHost.app"
[[ -d "$APP" ]] || die "Export produced no PupaHost.app in $EXPORT_DIR."

# --- verify the signed product --------------------------------------------
# --require-embedded-profile is the Developer ID-specific half: iCloud is a
# restricted entitlement, so without an embedded profile the app launches
# normally and then never syncs, with nothing shown to the user.
scripts/verify-mac-entitlements.sh "$APP" --require-embedded-profile

codesign --verify --strict --deep "$APP" 2>/dev/null \
  || die "codesign --verify failed on $APP."
CS_INFO=$(codesign -dv "$APP" 2>&1 || true)
[[ "$CS_INFO" == *"(runtime)"* ]] \
  || die "$APP is not hardened-runtime signed. Notarization would reject it."
note "signature valid, hardened runtime on"

# --- package the DMG ------------------------------------------------------
mkdir -p "$STAGE"
# ditto, not cp -R: it is the copy that preserves extended attributes and the
# signature across filesystems. A broken copy would notarize and then fail to
# launch, so re-verify after staging rather than trusting the copy.
ditto "$APP" "$STAGE/Pupa.app"
codesign --verify --strict --deep "$STAGE/Pupa.app" 2>/dev/null \
  || die "Signature broke while staging the app for the DMG."
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Pupa" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null \
  || die "hdiutil create failed."
# Sign the disk image itself, not just the app inside it. Notarization staples a
# ticket to the DMG either way, but Gatekeeper still evaluates the image's own
# signature — an unsigned one is "rejected: no usable signature" no matter how
# well the app inside is signed. Sign before submitting: signing after would
# invalidate the staple.
# Sign with whichever identity this run is using. A smoke test has no Developer
# ID by definition — that is the whole reason --development-signing exists — so
# demanding one here would break the flag for exactly the people it serves.
# Read from the already-captured IDENTITIES, and let awk run to EOF. Both
# `awk '{print; exit}'` and `awk … | head -1` stop reading early, which SIGPIPEs
# the producer and makes pipefail report 141 — the trap SKILL.md warns about. A
# first-match flag is the only shape here that is safe at any input size.
if [[ $DEV_SIGNING -eq 1 ]]; then
  SIGN_AS="Apple Development"
else
  SIGN_AS="Developer ID Application"
fi
DEVID=$(printf '%s\n' "$IDENTITIES" | awk -v want="$SIGN_AS" 'index($0, want) && !seen { print $2; seen = 1 }')
[[ -n "$DEVID" ]] || die "Could not resolve a '$SIGN_AS' identity to sign the DMG."
CODESIGN_ERR=$(codesign --force --sign "$DEVID" --timestamp "$DMG" 2>&1) \
  || die "codesign failed on $DMG:
       $CODESIGN_ERR"
CODESIGN_ERR=$(codesign --verify --strict "$DMG" 2>&1) \
  || die "codesign --verify failed on $DMG:
       $CODESIGN_ERR"
note "packaged and signed $DMG"

BUNDLE_SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')
BUNDLE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')
[[ "$BUNDLE_SHORT" == "$VERSION" ]] \
  || die "The packaged app reports version $BUNDLE_SHORT, expected $VERSION.
       MARKETING_VERSION did not take — the DMG would advertise the wrong version."

# The DMG inherits CURRENT_PROJECT_VERSION from project.pbxproj, which archive.sh
# owns. If the two channels ship the same marketing version with different build
# numbers, a Sparkle updater — which orders by CFBundleVersion alone and ignores
# the marketing string — sees them as different builds. Assert they agree.
PBX_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed -E 's/.*= *([0-9]+).*/\1/' || true)
[[ -n "$PBX_BUILD" && "$BUNDLE_BUILD" == "$PBX_BUILD" ]] \
  || die "The packaged app reports build $BUNDLE_BUILD but project.pbxproj says ${PBX_BUILD:-?}.
       The App Store and DMG channels would ship the same version as different builds."


if [[ $SKIP_NOTARIZE -eq 1 ]]; then
  if [[ $DEV_SIGNING -eq 1 ]]; then
    cat <<EOF

PIPELINE SMOKE TEST PASSED — THIS DMG IS NOT A RELEASE
  $DMG
  Bundle reports $BUNDLE_SHORT (build $BUNDLE_BUILD), signed with an Apple
  Development identity

Everything up to notarization ran: archive, export, entitlement + embedded
profile checks, staging, signature re-verify, packaging. Notarization itself is
untested — Apple only notarizes Developer ID signatures.

Delete this file. It is signed for this machine, cannot be notarized, and must
never be published. Building it claims nothing and blocks nothing: a later
release under any Developer ID is an independent signature and submission.
EOF
  else
    cat <<EOF

DMG BUILT (NOT NOTARIZED)
  $DMG
  Version $VERSION, team $TEAM

Gatekeeper will refuse this on any machine but this one. Re-run without
--skip-notarize before publishing it anywhere.
EOF
  fi
  exit 0
fi

# --- notarize + staple ----------------------------------------------------
# Notarize the DMG rather than the .app: the ticket then travels with the file
# users actually download, so Gatekeeper is satisfied on first launch offline.
note "submitting to Apple for notarization (usually 1–5 min)..."
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
  || die "Notarization failed. Get the reason with:
       xcrun notarytool history --keychain-profile $NOTARY_PROFILE
       xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"

xcrun stapler staple "$DMG" || die "stapler staple failed on $DMG."
xcrun stapler validate "$DMG" >/dev/null || die "stapler validate failed on $DMG."
note "notarized and stapled"

# Gatekeeper's own verdict, which is what a user's Mac will compute.
SPCTL=$(spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 || true)
[[ "$SPCTL" == *accepted* ]] \
  || die "spctl rejected $DMG — Gatekeeper would refuse it:
       $SPCTL"

if [[ $PUBLISH -eq 1 ]]; then
  # Upload under a constant filename so the website can hardcode one permanent
  # link — https://github.com/<owner>/<repo>/releases/latest/download/Pupa.dmg
  # only resolves when the asset name is the same in every release. The version
  # lives in the tag and title.
  STABLE="build/Pupa.dmg"
  cp "$DMG" "$STABLE"

  # Release notes are the CHANGELOG section for this version, verbatim.
  NOTES=$(mktemp -t pupa-notes)
  trap 'rm -f "$NOTES"' EXIT
  awk -v v="## [$VERSION]" '
    index($0, v) == 1 { inside = 1; next }
    inside && /^## \[/ { exit }
    inside { print }
  ' CHANGELOG.md > "$NOTES"
  [[ -s "$NOTES" ]] || die "No CHANGELOG section found for $VERSION — write one before publishing."

  if gh release view "v$VERSION" >/dev/null 2>&1; then
    # Replacing the asset on a *published* release changes what users are
    # already downloading. Drafts are fair game; live releases are not.
    [[ "$(gh release view "v$VERSION" --json isDraft -q .isDraft)" == "true" ]] \
      || die "Release v$VERSION is already published. Refusing to replace a live download.
       Publish a new version instead, or delete the asset by hand if it is genuinely wrong."
    note "draft release v$VERSION exists — replacing its asset"
    gh release upload "v$VERSION" "$STABLE" --clobber >/dev/null \
      || die "gh release upload failed."
  else
    gh release create "v$VERSION" "$STABLE" \
      --draft --title "Pupa $VERSION" --notes-file "$NOTES" >/dev/null \
      || die "gh release create failed."
  fi
  RELEASE_URL=$(gh release view "v$VERSION" --json url -q .url)
  note "draft release ready: $RELEASE_URL"
fi

cat <<EOF

DMG READY
  $DMG
  Bundle reports $BUNDLE_SHORT (build $BUNDLE_BUILD), notarized and stapled,
  Gatekeeper accepted${RELEASE_URL:+

  Draft release: $RELEASE_URL
  Review it and publish by hand — publishing is a human step. Note that while
  the repo is private, the download link only works for authenticated users.}

Verify on a machine that has never seen this build (or clear the quarantine
cache) before publishing. Upload it wherever the download link points, and
remember the update channel is still manual — see pupa#246 step 4.
EOF
