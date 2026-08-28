#!/usr/bin/env bash
#
# verify-mac-entitlements.sh <.app or .xcarchive> [--require-embedded-profile]
#
# Assert the signed macOS product carries exactly the entitlements we intend.
# Both release paths call this: testflight-release (App Store) and dmg-release
# (Developer ID). One definition so the two channels cannot drift apart — that
# is the whole premise of pupa#246.
#
# Entitlements exist only in a signed product, so no unit test can cover any of
# this. Three failure modes, all silent at runtime:
#
#   missing security key -> the feature is simply dead (pupa#229: the Mac build
#                           shipped with no outbound network, localhost included)
#   extra security key   -> App Store review asks why we want a door we never open
#   wrong iCloud container -> the two channels sync to different places, or one
#                           syncs nowhere, and the user's data quietly diverges
#
# The signature is the only ground truth. Do NOT read PupaHost.entitlements to
# answer "are we sandboxed": the com.apple.security.* keys are synthesized from
# the ENABLE_* build settings and never appear in that file. See the entitlement
# table in docs/architecture.md.
set -euo pipefail

# The container id lives in Swift, so the check can't drift from the app.
CONTAINER_SOURCE="Pupa/Sources/PupaApp/Sync/PupaStorage.swift"

EXPECTED_SECURITY="com.apple.security.app-sandbox
com.apple.security.files.user-selected.read-write
com.apple.security.network.client
com.apple.security.network.server"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "→ $*"; }

TARGET="${1:-}"
REQUIRE_PROFILE=0
[[ -n "$TARGET" ]] || die "usage: $0 <.app or .xcarchive> [--require-embedded-profile]"
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-embedded-profile) REQUIRE_PROFILE=1; shift;;
    *) die "unknown flag: $1";;
  esac
done

# Accept either an archive or the .app itself, so the App Store path can pass
# its .xcarchive and the Developer ID path its exported bundle.
if [[ "$TARGET" == *.xcarchive ]]; then
  APP=$(echo "$TARGET"/Products/Applications/*.app)
else
  APP="$TARGET"
fi
[[ -d "$APP" ]] || die "No app bundle at $APP."
[[ -f "$CONTAINER_SOURCE" ]] || die "Run from the repo root. Could not find $CONTAINER_SOURCE."

# `|| true` so the explicit guard below reports the problem. Without it, a failing
# substitution trips `set -e` and the script dies with no message at all.
EXPECTED_CONTAINER=$(grep 'containerID = ' "$CONTAINER_SOURCE" | sed -E 's/.*"([^"]+)".*/\1/' || true)
[[ -n "$EXPECTED_CONTAINER" ]] || die "Could not read PupaStorage.containerID from $CONTAINER_SOURCE."

ENT=$(mktemp -t pupa-entitlements)
trap 'rm -f "$ENT"' EXIT
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o "$ENT" - 2>/dev/null \
  || die "Could not read entitlements from $APP. Is it signed?"

# --- 1. the com.apple.security.* set --------------------------------------
# get-task-allow is a signing-mode artefact (development vs distribution), not
# a capability we choose, so it never takes part in the comparison.
ACTUAL_SECURITY=$(grep -o 'com\.apple\.security\.[a-z.-]*' "$ENT" \
  | grep -v '^com\.apple\.security\.get-task-allow$' \
  | sort -u || true)
[[ -n "$ACTUAL_SECURITY" ]] || die "No com.apple.security.* entitlements in $APP. Is it signed for macOS?"

if ! DRIFT=$(diff <(printf '%s\n' "$EXPECTED_SECURITY" | sort) <(printf '%s\n' "$ACTUAL_SECURITY")); then
  printf '%s\n' "$DRIFT" >&2
  die "macOS entitlements drifted ('<' expected but absent, '>' present but unexpected).
       Every key must be justified by code that uses it — see the entitlement table in
       docs/architecture.md. If the change is intentional, update EXPECTED_SECURITY in
       this script and that table in the same commit."
fi

# --- 2. the iCloud container ----------------------------------------------
# Both channels must land in the same ubiquity container or user data silently
# forks. On a Developer ID build this is also how a missing embedded profile
# shows up: iCloud is a restricted entitlement, so without the profile the keys
# never make it into the signature.
container_values() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$ENT" 2>/dev/null \
    | sed -n 's/^[[:space:]]*\(iCloud\.[^[:space:]]*\)[[:space:]]*$/\1/p' | sort -u
}

for key in com.apple.developer.icloud-container-identifiers \
           com.apple.developer.ubiquity-container-identifiers; do
  # `|| true` for the same reason as the read above: container_values is a
  # pipeline whose first command exits 1 on a missing key, so without it `set -e`
  # kills the script before the die below — silently, on exactly the condition
  # this guard exists to report.
  actual=$(container_values "$key" || true)
  [[ -n "$actual" ]] || die "$APP is missing $key.
       On a Developer ID build this usually means no .provisionprofile is embedded — iCloud
       is a restricted entitlement, so the app will launch fine and then never sync."
  [[ "$actual" == "$EXPECTED_CONTAINER" ]] \
    || die "$key is '$actual', expected '$EXPECTED_CONTAINER' (PupaStorage.containerID).
       A mismatch puts this channel on a different iCloud container from the other one."
done

grep -q '<string>CloudDocuments</string>' "$ENT" \
  || die "$APP does not declare the CloudDocuments iCloud service. Sync will not work."

# --- 3. embedded provisioning profile (Developer ID only) -----------------
if [[ $REQUIRE_PROFILE -eq 1 ]]; then
  [[ -f "$APP/Contents/embedded.provisionprofile" ]] \
    || die "No Contents/embedded.provisionprofile in $APP.
       A Developer ID build must embed one or the ubiquity container will not resolve at
       runtime: PupaStorage.documentsRoot returns nil, iCloudActive is false, and the app
       runs local-only with no error shown."
  note "embedded.provisionprofile present"
fi

note "macOS entitlements verified — sandbox, network client+server, user-selected files, iCloud container $EXPECTED_CONTAINER"
