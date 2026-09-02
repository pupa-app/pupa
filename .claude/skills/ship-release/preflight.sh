#!/usr/bin/env bash
#
# ship-release / preflight.sh
#
# Answer "can both channels ship from this checkout?" in about a second, before
# anything slow starts. Every check here failed late in a real release once:
# a MARKETING_VERSION the release PR forgot, a tag that was never pushed, a
# notary profile nobody remembered the name of, a disk with no room for the
# second archive. None of them are worth discovering eight minutes into an
# xcodebuild.
#
# Reports every failure rather than stopping at the first, so one run lists
# everything to fix. Exit 0 = both channels are clear to run.
#
# usage: preflight.sh [--publish]
#   --publish  also require what --publish needs: the tag on origin, HEAD at
#              that tag, and a non-empty CHANGELOG section.
set -uo pipefail

PBXPROJ="PupaHost/PupaHost.xcodeproj/project.pbxproj"
VERSION_SWIFT="Pupa/Sources/PupaApp/Version.swift"
LOCAL_XCCONFIG="PupaHost/Local.xcconfig"

WANT_PUBLISH=0
[[ "${1:-}" == "--publish" ]] && WANT_PUBLISH=1

FAILED=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAILED=1; printf '  \033[31mno\033[0m   %s\n       %s\n' "$1" "$2"; }
skip() { printf '  --   %s\n' "$1"; }

[[ -f "$PBXPROJ" ]] || { echo "error: run from the repo root." >&2; exit 2; }

VERSION=$(grep 'PupaAppVersion: String' "$VERSION_SWIFT" | sed -E 's/.*"([^"]+)".*/\1/')
echo
echo "ship-release preflight — Pupa $VERSION"
echo

# --- the release PR's job -------------------------------------------------
# archive.sh syncs MARKETING_VERSION itself and then needs to commit, which it
# refuses to do on dev or main. That refusal mid-release is what a drifted
# pbxproj actually looks like, so name the cause here instead.
MV=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);/\1/p' "$PBXPROJ" | head -1)
if [[ "$MV" == "$VERSION" ]]; then
  ok "MARKETING_VERSION matches PupaAppVersion ($VERSION)"
else
  bad "MARKETING_VERSION is $MV, PupaAppVersion is $VERSION" \
      "Set it in the release PR. Left alone, archive.sh syncs it and then has a commit to land, which it refuses to do on dev or main."
fi

BUILD=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([0-9]{2,});/\1/p' "$PBXPROJ" | head -1)
COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)
if [[ -z "$BUILD" ]]; then
  bad "no app CURRENT_PROJECT_VERSION found in $PBXPROJ" "Expected a two-digit-or-longer build number."
elif (( BUILD >= COUNT )); then
  ok "CURRENT_PROJECT_VERSION is $BUILD (commit count $COUNT)"
else
  bad "CURRENT_PROJECT_VERSION is $BUILD, behind the commit count $COUNT" \
      "Set it in the release PR. Both channels must ship the same CFBundleVersion — Sparkle orders DMG updates by build number alone."
fi

# --- signing and credentials ----------------------------------------------
if [[ -f "$LOCAL_XCCONFIG" ]] && grep -qE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Za-z0-9]+' "$LOCAL_XCCONFIG"; then
  ok "DEVELOPMENT_TEAM present in $LOCAL_XCCONFIG"
else
  bad "no DEVELOPMENT_TEAM in $LOCAL_XCCONFIG" "cp $LOCAL_XCCONFIG.example $LOCAL_XCCONFIG and fill in the team id."
fi

IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
[[ "$IDENTITIES" == *"Developer ID Application"* ]] \
  && ok "Developer ID Application certificate in the keychain" \
  || bad "no Developer ID Application certificate" "The DMG channel cannot sign without it. developer.apple.com → Certificates, Account Holder only."

PROFILE="${NOTARY_PROFILE:-}"
[[ -z "$PROFILE" && -f "$LOCAL_XCCONFIG" ]] && PROFILE=$(sed -nE 's/^[[:space:]]*NOTARY_PROFILE[[:space:]]*=[[:space:]]*([A-Za-z0-9._-]+).*/\1/p' "$LOCAL_XCCONFIG" | head -1)
if [[ -z "$PROFILE" ]]; then
  bad "no notarytool profile name" "Add a NOTARY_PROFILE line to $LOCAL_XCCONFIG, or pass --notary-profile. Create one with: xcrun notarytool store-credentials"
elif [[ "${PUPA_PREFLIGHT_OFFLINE:-0}" == "1" ]]; then
  skip "notarytool profile '$PROFILE' (not checked — offline)"
elif xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  ok "notarytool profile '$PROFILE' authenticates"
else
  bad "notarytool profile '$PROFILE' does not authenticate" "Re-store it: xcrun notarytool store-credentials"
fi

# --- room to work ---------------------------------------------------------
# 12G covers both TestFlight archives; the DMG run needs 8G of that again after
# they are written, so ask for the larger number up front.
if SPACE=$(scripts/require-free-space.sh 12 "both channels" 2>&1); then
  ok "disk has room for both channels"
else
  bad "not enough free disk" "${SPACE#error: }"
fi

# --- what --publish additionally needs ------------------------------------
if [[ $WANT_PUBLISH -eq 1 ]]; then
  if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
    ok "tag v$VERSION exists on origin"
    TAGGED=$(git rev-parse "v$VERSION^{}" 2>/dev/null || echo "")
    HEAD_SHA=$(git rev-parse HEAD)
    if [[ -n "$TAGGED" && "$TAGGED" != "$HEAD_SHA" ]]; then
      # A warning, not a refusal: guards that hard-failed here rejected
      # legitimate releases (pupa#297). Procedure lives in CONTRIBUTING.
      skip "HEAD is not the tagged commit — build from the tag (CONTRIBUTING → Releases)"
    fi
  else
    bad "tag v$VERSION is not on origin" "git tag v$VERSION && git push origin v$VERSION — a human step."
  fi

  NOTES=$(awk -v v="## [$VERSION]" 'index($0, v) == 1 { inside = 1; next } inside && /^## \[/ { exit } inside { print }' CHANGELOG.md | tr -d '[:space:]')
  [[ -n "$NOTES" ]] \
    && ok "CHANGELOG has a section for $VERSION" \
    || bad "CHANGELOG has no non-empty section for $VERSION" "Write one — it becomes the release notes verbatim."
fi

echo
if [[ $FAILED -eq 0 ]]; then
  printf '\033[32mclear to ship\033[0m\n'
  exit 0
fi
printf '\033[31mfix the above before starting\033[0m — every one of these fails late otherwise\n'
exit 1
