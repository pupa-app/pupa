#!/usr/bin/env bash
#
# testflight-release / archive.sh
#
# Produce a signed .xcarchive of PupaHost ready for TestFlight upload via Xcode Organizer.
# See SKILL.md next to this file for usage.
#
set -euo pipefail

# Paths relative to repo root
PBXPROJ="PupaHost/PupaHost.xcodeproj/project.pbxproj"
VERSION_SWIFT="Pupa/Sources/PupaApp/Version.swift"
ICON="PupaHost/PupaHost/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
SCHEME="PupaHost"
PROJECT="PupaHost/PupaHost.xcodeproj"
ARCHIVE="build/Pupa.xcarchive"

# --- arg parsing ----------------------------------------------------------
BUILD_OVERRIDE=""
NO_BUMP=0
SKIP_ICON=0
usage() {
  cat <<EOF
usage: $0 [--build N] [--no-bump] [--skip-icon-check]
  --build N            Set CURRENT_PROJECT_VERSION to N (default: current + 1)
  --no-bump            Don't change the build number
  --skip-icon-check    Skip alpha-channel check on icon_1024.png
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD_OVERRIDE="${2:-}"; shift 2;;
    --no-bump) NO_BUMP=1; shift;;
    --skip-icon-check) SKIP_ICON=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
note() { echo "→ $*"; }

# --- preconditions --------------------------------------------------------
[[ -f "$PBXPROJ" ]] || die "Run from repo root. Could not find $PBXPROJ."
[[ -f "$VERSION_SWIFT" ]] || die "Could not find $VERSION_SWIFT."
[[ -f "$ICON" ]] || die "Could not find $ICON."
command -v xcodebuild >/dev/null || die "xcodebuild not on PATH."

# Working tree: only pbxproj is allowed to be dirty (we may modify it below)
DIRTY=$(git status --porcelain | awk '{print $2}' | grep -v "^${PBXPROJ}\$" || true)
if [[ -n "$DIRTY" ]]; then
  echo "Working tree has uncommitted changes besides pbxproj:" >&2
  echo "$DIRTY" >&2
  die "Commit or stash these before archiving."
fi

# --- icon alpha check -----------------------------------------------------
if [[ $SKIP_ICON -eq 0 ]]; then
  ALPHA=$(sips -g hasAlpha "$ICON" 2>/dev/null | awk '/hasAlpha/{print $2}')
  if [[ "$ALPHA" != "no" ]]; then
    die "$ICON has alpha channel (App Store Connect rejects 1024×1024 icons with alpha — shows wireframe placeholder). Flatten it before archiving."
  fi
  note "icon_1024.png has no alpha channel"
fi

# --- read versions --------------------------------------------------------
# PupaAppVersion (source of truth for marketing version)
TARGET_MV=$(grep 'PupaAppVersion: String' "$VERSION_SWIFT" | sed -E 's/.*"([^"]+)".*/\1/')
[[ -n "$TARGET_MV" ]] || die "Could not read PupaAppVersion from $VERSION_SWIFT."

# Current MARKETING_VERSION for app target (the one ≠ "1.0", which is the test target default)
CURRENT_MV=$(grep -E 'MARKETING_VERSION = [^;]+;' "$PBXPROJ" | grep -v '= 1\.0;' | head -1 | awk '{print $3}' | tr -d ';')
[[ -n "$CURRENT_MV" ]] || die "Could not read app target's MARKETING_VERSION from $PBXPROJ."

# Current CURRENT_PROJECT_VERSION for app target (the one ≠ "1", which is the test target default)
CURRENT_BUILD=$(grep -E 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PBXPROJ" | grep -v '= 1;' | head -1 | awk '{print $3}' | tr -d ';')
[[ -n "$CURRENT_BUILD" ]] || die "Could not read app target's CURRENT_PROJECT_VERSION from $PBXPROJ."

# Compute new build number
if [[ $NO_BUMP -eq 1 ]]; then
  NEW_BUILD="$CURRENT_BUILD"
elif [[ -n "$BUILD_OVERRIDE" ]]; then
  NEW_BUILD="$BUILD_OVERRIDE"
else
  NEW_BUILD=$((CURRENT_BUILD + 1))
fi

# --- apply pbxproj edits --------------------------------------------------
NEEDS_COMMIT=0

if [[ "$CURRENT_MV" != "$TARGET_MV" ]]; then
  sed -i '' "s/MARKETING_VERSION = ${CURRENT_MV};/MARKETING_VERSION = ${TARGET_MV};/g" "$PBXPROJ"
  note "synced MARKETING_VERSION ${CURRENT_MV} → ${TARGET_MV} (from PupaAppVersion)"
  NEEDS_COMMIT=1
fi

if [[ "$NEW_BUILD" != "$CURRENT_BUILD" ]]; then
  sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD};/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" "$PBXPROJ"
  note "bumped CURRENT_PROJECT_VERSION ${CURRENT_BUILD} → ${NEW_BUILD}"
  NEEDS_COMMIT=1
fi

if [[ $NEEDS_COMMIT -eq 1 ]]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  git add "$PBXPROJ"
  git commit -m "$(printf 'chore(ios): bump build to %s\n\nAI generated' "$NEW_BUILD")" >/dev/null
  note "committed pbxproj changes on '${BRANCH}' (not pushed)"
fi

# --- archive --------------------------------------------------------------
note "archiving (this takes 3–5 min)..."
mkdir -p build
rm -rf "$ARCHIVE"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  archive \
  >/tmp/pupa-archive.log 2>&1 \
  || { tail -40 /tmp/pupa-archive.log >&2; die "xcodebuild archive failed. See /tmp/pupa-archive.log for full output."; }

# --- verify ---------------------------------------------------------------
A_VERSION=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" "$ARCHIVE/Info.plist")
A_BUILD=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "$ARCHIVE/Info.plist")
A_BUNDLE=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleIdentifier" "$ARCHIVE/Info.plist")

cat <<EOF

ARCHIVE READY
  Path:    $ARCHIVE
  Version: $A_VERSION
  Build:   $A_BUILD
  Bundle:  $A_BUNDLE

Next step: Open Xcode → Window → Organizer (⌥⇧⌘O), select this archive, click Distribute App → App Store Connect → Upload.
EOF
