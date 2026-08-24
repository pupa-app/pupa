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
usage() {
  cat <<EOF
usage: $0 [--notary-profile NAME] [--skip-notarize]
  --notary-profile NAME  notarytool keychain profile (or set NOTARY_PROFILE).
                         Create once with: xcrun notarytool store-credentials
  --skip-notarize        Archive, export and package only. The DMG will be
                         signed but NOT notarized — Gatekeeper will refuse it on
                         any other Mac. Local validation only.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notary-profile) NOTARY_PROFILE="${2:-}"; shift 2;;
    --skip-notarize) SKIP_NOTARIZE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
note() { echo "→ $*"; }

# --- preconditions --------------------------------------------------------
[[ -f "$PBXPROJ" ]] || die "Run from repo root. Could not find $PBXPROJ."
command -v xcodebuild >/dev/null || die "xcodebuild not on PATH."

# Developer ID is a different certificate from the Apple Development one used
# for TestFlight. Without it the export silently falls back and Gatekeeper
# rejects the result on every machine but this one.
security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" \
  || die "No 'Developer ID Application' certificate in the keychain.
       Create one at developer.apple.com → Certificates (Account Holder only; Apple caps
       these at 5 per account, so back the private key up). An Apple Development cert
       will not do — it is not trusted off this machine."

[[ -f "$LOCAL_XCCONFIG" ]] || die "Missing $LOCAL_XCCONFIG (git-ignored). It must hold: DEVELOPMENT_TEAM = <your team id>"
TEAM=$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' "$LOCAL_XCCONFIG" | sed -E 's/.*=[[:space:]]*([A-Za-z0-9]+).*/\1/')
[[ -n "$TEAM" ]] || die "Could not read DEVELOPMENT_TEAM from $LOCAL_XCCONFIG."

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  [[ -n "$NOTARY_PROFILE" ]] || die "Pass --notary-profile NAME (or set NOTARY_PROFILE), or use --skip-notarize.
       Store credentials once with:  xcrun notarytool store-credentials"
  xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found. Needs Xcode 13+."
fi

VERSION=$(grep 'PupaAppVersion: String' "$VERSION_SWIFT" | sed -E 's/.*"([^"]+)".*/\1/')
[[ -n "$VERSION" ]] || die "Could not read PupaAppVersion from $VERSION_SWIFT."
DMG="build/Pupa-$VERSION.dmg"
note "building Pupa $VERSION for the Developer ID channel"

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
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST

note "exporting with Developer ID..."
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
codesign -dv "$APP" 2>&1 | grep -q 'flags=.*runtime' \
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
note "packaged $DMG"

if [[ $SKIP_NOTARIZE -eq 1 ]]; then
  cat <<EOF

DMG BUILT (NOT NOTARIZED)
  $DMG
  Version $VERSION, team $TEAM

Gatekeeper will refuse this on any machine but this one. Re-run without
--skip-notarize before publishing it anywhere.
EOF
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
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | grep -q accepted \
  || die "spctl rejected $DMG — Gatekeeper would refuse it."

cat <<EOF

DMG READY
  $DMG
  Version $VERSION, notarized and stapled, Gatekeeper accepted

Verify on a machine that has never seen this build (or clear the quarantine
cache) before publishing. Upload it wherever the download link points, and
remember the update channel is still manual — see pupa#246 step 4.
EOF
