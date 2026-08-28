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
ICON_BUNDLE="PupaHost/PupaHost/AppIcon.icon"
ICON_MARK="$ICON_BUNDLE/Assets/mark.png"
SCHEME="PupaHost"
PROJECT="PupaHost/PupaHost.xcodeproj"
ARCHIVE_IOS="build/Pupa.xcarchive"
ARCHIVE_MACOS="build/Pupa-macOS.xcarchive"

# Release git flow: bump lands on $DEV_BRANCH, then $MAIN_BRANCH is
# fast-forwarded from it, so the branches stay aligned (no post-hoc realign).
DEV_BRANCH="${DEV_BRANCH:-dev}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"

# --- arg parsing ----------------------------------------------------------
BUILD_OVERRIDE=""
NO_BUMP=0
SKIP_ICON=0
# The dev→main dance is opt-in. Moving `main` is forbidden to assistants and is
# a human release act either way (CONTRIBUTING → AI assistants), so the default
# is to bump and archive in place and let a human move branches.
FLOW=0
usage() {
  cat <<EOF
usage: $0 [--build N] [--no-bump] [--skip-icon-check] [--flow]
  --build N            Set CURRENT_PROJECT_VERSION to N (must exceed the current
                       build; default: commit count, see below)
  --no-bump            Don't change the build number
  --skip-icon-check    Skip the icon_1024.png / AppIcon.icon integrity checks
  --flow               Also switch to $DEV_BRANCH, commit the bump there, and
                       fast-forward $MAIN_BRANCH from it before archiving. Human-only:
                       moving $MAIN_BRANCH is forbidden to assistants. Off by default,
                       in which case the current branch is bumped and archived in
                       place and branch movement is left to you.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD_OVERRIDE="${2:-}"; shift 2;;
    --no-bump) NO_BUMP=1; shift;;
    --skip-icon-check) SKIP_ICON=1; shift;;
    --flow) FLOW=1; shift;;
    --no-flow) FLOW=0; shift;;   # accepted for compatibility; now the default
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

# --- release flow: move to dev so the bump lands there first --------------
# The build bump is committed on $DEV_BRANCH, then $MAIN_BRANCH is
# fast-forwarded from it after the commit (see below). This keeps both
# branches pointing at the same SHA — no need to realign main→dev afterward.
START_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ $FLOW -eq 1 ]]; then
  git rev-parse --verify --quiet "$DEV_BRANCH" >/dev/null \
    || die "Branch '$DEV_BRANCH' not found (only needed with --flow)."
  git rev-parse --verify --quiet "$MAIN_BRANCH" >/dev/null \
    || die "Branch '$MAIN_BRANCH' not found (only needed with --flow)."
  if [[ "$START_BRANCH" != "$DEV_BRANCH" ]]; then
    git checkout "$DEV_BRANCH" >/dev/null 2>&1 || die "Could not checkout '$DEV_BRANCH'."
    note "switched to '$DEV_BRANCH' to land the build bump"
  fi
fi

# --- icon checks ----------------------------------------------------------
# Two files, opposite alpha requirements:
#   icon_1024.png            master source art, must be OPAQUE
#   AppIcon.icon/…/mark.png  Icon Composer layer, must HAVE alpha
if [[ $SKIP_ICON -eq 0 ]]; then
  ALPHA=$(sips -g hasAlpha "$ICON" 2>/dev/null | awk '/hasAlpha/{print $2}' || true)
  if [[ "$ALPHA" != "no" ]]; then
    die "$ICON has alpha channel (App Store Connect rejects 1024×1024 icons with alpha — shows wireframe placeholder). Flatten it before archiving."
  fi
  note "icon_1024.png has no alpha channel"

  [[ -f "$ICON_BUNDLE/icon.json" ]] || die "Missing $ICON_BUNDLE/icon.json."
  [[ -f "$ICON_MARK" ]] || die "Missing $ICON_MARK — run: swift scripts/gen-icon-mark.swift"
  MARK_ALPHA=$(sips -g hasAlpha "$ICON_MARK" 2>/dev/null | awk '/hasAlpha/{print $2}' || true)
  [[ "$MARK_ALPHA" == "yes" ]] \
    || die "$ICON_MARK has no alpha (the mark must be transparent-backed). Regenerate: swift scripts/gen-icon-mark.swift"
  grep -q '"glass" : false' "$ICON_BUNDLE/icon.json" \
    || die "$ICON_BUNDLE/icon.json lost \"glass\": false — the icon would ship with Liquid Glass blur."
  note "AppIcon.icon intact (alpha mark, glass off)"
fi

# --- read versions --------------------------------------------------------
# PupaAppVersion (source of truth for marketing version)
TARGET_MV=$(grep 'PupaAppVersion: String' "$VERSION_SWIFT" | sed -E 's/.*"([^"]+)".*/\1/' || true)
[[ -n "$TARGET_MV" ]] || die "Could not read PupaAppVersion from $VERSION_SWIFT."

# Current MARKETING_VERSION for app target (the one ≠ "1.0", which is the test target default)
CURRENT_MV=$(grep -E 'MARKETING_VERSION = [^;]+;' "$PBXPROJ" | grep -v '= 1\.0;' | awk 'NR==1{print $3}' | tr -d ';' || true)
[[ -n "$CURRENT_MV" ]] || die "Could not read app target's MARKETING_VERSION from $PBXPROJ."

# Current CURRENT_PROJECT_VERSION for the app target. Identify the app target's
# build-config block by the MARKETING_VERSION we just read (CURRENT_MV); the
# CURRENT_PROJECT_VERSION line precedes MARKETING_VERSION within the same block.
# (Can't just skip "= 1;" — the test targets sit at the default 1 and the app
# build could legitimately pass through it too.)
CURRENT_BUILD=$(awk -v mv="$CURRENT_MV" '
  /CURRENT_PROJECT_VERSION = [0-9]+;/ { b=$3; gsub(";","",b) }
  $0 ~ "MARKETING_VERSION = " mv ";" { print b; exit }
' "$PBXPROJ")
[[ -n "$CURRENT_BUILD" ]] || die "Could not read app target's CURRENT_PROJECT_VERSION from $PBXPROJ."

# Compute new build number.
#
# CURRENT_PROJECT_VERSION (CFBundleVersion) must increase MONOTONICALLY across
# the whole product, and must NEVER reset on a marketing-version bump. Sparkle
# — which will drive the direct-download DMG channel — orders updates by
# CFBundleVersion alone and ignores the marketing string, so a reset (0.0.236
# build 3 → 0.0.237 build 1) reads as a downgrade and strands DMG users on the
# old build forever, silently. App Store Connect only requires uniqueness within
# a marketing version, so monotonic satisfies TestFlight too. See pupa#246.
#
# The default is the commit count on the current branch: monotonic by
# construction (the release branch only ever gains commits), automatic, and
# nothing to track by hand. The max() floor keeps the invariant even if the
# count comes back low — a shallow clone, or history rewritten under us.
if [[ $NO_BUMP -eq 1 ]]; then
  NEW_BUILD="$CURRENT_BUILD"
elif [[ -n "$BUILD_OVERRIDE" ]]; then
  [[ "$BUILD_OVERRIDE" =~ ^[0-9]+$ ]] || die "--build must be a positive integer, got '$BUILD_OVERRIDE'."
  [[ "$BUILD_OVERRIDE" -gt "$CURRENT_BUILD" ]] \
    || die "--build $BUILD_OVERRIDE does not exceed the current build $CURRENT_BUILD. CFBundleVersion must increase monotonically — a lower or equal value is rejected by App Store Connect and reads as a downgrade to Sparkle."
  NEW_BUILD="$BUILD_OVERRIDE"
else
  COMMIT_COUNT=$(git rev-list --count HEAD)
  NEW_BUILD=$(( COMMIT_COUNT > CURRENT_BUILD ? COMMIT_COUNT : CURRENT_BUILD + 1 ))
fi

# --- apply pbxproj edits --------------------------------------------------
# Work out whether an edit is needed *before* making one. The commit below is not
# gated on --flow (a MARKETING_VERSION sync sets NEEDS_COMMIT even under
# --no-bump), and committing on `main` or a detached tag checkout is refused — so
# refuse first and leave the file alone. Restoring it afterwards was worse: `git
# checkout --` also discards any pbxproj edit the user had made themselves, which
# the dirty-tree gate above deliberately permits.
NEEDS_COMMIT=0
[[ "$CURRENT_MV" != "$TARGET_MV" || "$NEW_BUILD" != "$CURRENT_BUILD" ]] && NEEDS_COMMIT=1

if [[ $NEEDS_COMMIT -eq 1 ]]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  case "$BRANCH" in
    "$MAIN_BRANCH"|HEAD)
      # List only what is actually pending, and only offer --no-bump when it
      # would change anything — a message naming 215 → 215, or suggesting a flag
      # the operator already passed, is the kind of dead-end remedy this script
      # has produced before.
      PENDING=""
      [[ "$CURRENT_MV" != "$TARGET_MV" ]] \
        && PENDING="MARKETING_VERSION ${CURRENT_MV} → ${TARGET_MV}"
      [[ "$NEW_BUILD" != "$CURRENT_BUILD" ]] \
        && PENDING="${PENDING:+$PENDING, }CURRENT_PROJECT_VERSION ${CURRENT_BUILD} → ${NEW_BUILD}"
      REMEDY=""
      [[ $NO_BUMP -eq 0 && "$NEW_BUILD" != "$CURRENT_BUILD" && "$CURRENT_MV" == "$TARGET_MV" ]] \
        && REMEDY="
       Or pass --no-bump if the build number is already correct."
      die "Refusing to change $PBXPROJ on '$BRANCH' — it would need a commit here.
       Pending: ${PENDING}.
       Land it in the release PR on ${DEV_BRANCH} and re-tag (see CONTRIBUTING → Releases).${REMEDY}" ;;
  esac

  # Also before editing: `git add` below stages the whole file, so a pbxproj edit
  # of the user's own — which the dirty gate deliberately permits — would be swept
  # into a commit titled "bump build to N", and under --flow onto $MAIN_BRANCH.
  # Tested after the edits this can only ever see the script's own change, and
  # would refuse every legitimate bump.
  git diff --quiet HEAD -- "$PBXPROJ" \
    || die "You have uncommitted changes in $PBXPROJ. The bump commit would absorb them.
       Commit or stash them first:  git stash push -- $PBXPROJ"
fi

if [[ "$CURRENT_MV" != "$TARGET_MV" ]]; then
  sed -i '' "s/MARKETING_VERSION = ${CURRENT_MV};/MARKETING_VERSION = ${TARGET_MV};/g" "$PBXPROJ"
  note "synced MARKETING_VERSION ${CURRENT_MV} → ${TARGET_MV} (from PupaAppVersion)"
fi

if [[ "$NEW_BUILD" != "$CURRENT_BUILD" ]]; then
  # Bump CURRENT_PROJECT_VERSION only inside app-target buildSettings blocks
  # (those carrying the app MARKETING_VERSION). A global sed would also hit
  # the test targets — which share the default value 1 — and the doc promises
  # they stay at 1. Buffer each buildSettings block; the build line precedes
  # MARKETING_VERSION within it, so we can only rewrite once the block is known
  # to be the app's.
  awk -v mv="$TARGET_MV" -v old="$CURRENT_BUILD" -v new="$NEW_BUILD" '
    /buildSettings = \{/ { inblk=1; isapp=0; n=0; buf[n++]=$0; next }
    inblk {
      buf[n++]=$0
      if (index($0, "MARKETING_VERSION = " mv ";")) isapp=1
      if ($0 ~ /^[[:space:]]*\};[[:space:]]*$/) {
        for (i=0;i<n;i++) {
          line=buf[i]
          if (isapp && index(line, "CURRENT_PROJECT_VERSION = " old ";"))
            sub("CURRENT_PROJECT_VERSION = " old ";", "CURRENT_PROJECT_VERSION = " new ";", line)
          print line
        }
        inblk=0
      }
      next
    }
    { print }
  ' "$PBXPROJ" > "${PBXPROJ}.tmp" && mv "${PBXPROJ}.tmp" "$PBXPROJ"
  note "bumped CURRENT_PROJECT_VERSION ${CURRENT_BUILD} → ${NEW_BUILD} (app target only)"
fi

if [[ $NEEDS_COMMIT -eq 1 ]]; then
  git add "$PBXPROJ"
  git commit -m "$(printf 'chore(ios): bump build to %s\n\nAI generated' "$NEW_BUILD")" >/dev/null \
    || die "Committing $PBXPROJ failed — a pre-commit hook, most likely (this repo has one that
       rejects a non-empty DEVELOPMENT_TEAM). The bump is staged but not committed; see it with:
       git diff --cached -- $PBXPROJ"
  note "committed pbxproj changes on '${BRANCH}' (not pushed)"
fi

# --- fast-forward main from dev, then archive on main ---------------------
# Only under --flow. Runs even when nothing was committed, so an already-bumped
# dev still advances main. --ff-only refuses if the branches diverged.
if [[ $FLOW -eq 1 ]]; then
  git checkout "$MAIN_BRANCH" >/dev/null 2>&1 || die "Could not checkout '$MAIN_BRANCH'."
  git merge --ff-only "$DEV_BRANCH" >/dev/null 2>&1 \
    || die "Cannot fast-forward $MAIN_BRANCH from $DEV_BRANCH — they have diverged. Resolve manually, then re-run."
  note "fast-forwarded $MAIN_BRANCH from $DEV_BRANCH (push both with: git push origin $DEV_BRANCH $MAIN_BRANCH)"
fi

# --- archive (iOS + macOS — one Universal Purchase record, both ship together) ---
mkdir -p build

archive_platform() {
  local platform="$1" archive_path="$2"
  note "archiving $platform (this takes 3–5 min)..."
  rm -rf "$archive_path"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=$platform" \
    -archivePath "$archive_path" \
    -allowProvisioningUpdates \
    archive \
    >/tmp/pupa-archive-"${platform// /-}".log 2>&1 \
    || { tail -40 /tmp/pupa-archive-"${platform// /-}".log >&2; die "xcodebuild archive failed for $platform. See /tmp/pupa-archive-${platform// /-}.log for full output."; }
}

archive_platform "iOS" "$ARCHIVE_IOS"
archive_platform "macOS" "$ARCHIVE_MACOS"

# --- entitlement gate -----------------------------------------------------
# Shared with dmg-release, so the App Store and Developer ID channels cannot
# drift apart on the sandbox keys or the iCloud container. Entitlements exist
# only in a signed product, so this is the only regression guard there is.
scripts/verify-mac-entitlements.sh "$ARCHIVE_MACOS"

# --- verify ---------------------------------------------------------------
verify_archive() {
  local archive_path="$1"
  local v b i
  v=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" "$archive_path/Info.plist")
  b=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "$archive_path/Info.plist")
  i=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleIdentifier" "$archive_path/Info.plist")
  echo "$v|$b|$i"
}

IOS_INFO=$(verify_archive "$ARCHIVE_IOS")
MACOS_INFO=$(verify_archive "$ARCHIVE_MACOS")
IFS='|' read -r IOS_VERSION IOS_BUILD IOS_BUNDLE <<< "$IOS_INFO"
IFS='|' read -r MACOS_VERSION MACOS_BUILD MACOS_BUNDLE <<< "$MACOS_INFO"

PUSH_HINT=""
[[ $FLOW -eq 1 ]] && PUSH_HINT="
  Branches: $DEV_BRANCH and $MAIN_BRANCH aligned locally — push both:
            git push origin $DEV_BRANCH $MAIN_BRANCH"

cat <<EOF

ARCHIVES READY
  iOS:     $ARCHIVE_IOS
           Version $IOS_VERSION, Build $IOS_BUILD, Bundle $IOS_BUNDLE
  macOS:   $ARCHIVE_MACOS
           Version $MACOS_VERSION, Build $MACOS_BUILD, Bundle $MACOS_BUNDLE$PUSH_HINT

Next step: Open Xcode → Window → Organizer (⌥⇧⌘O). Both archives should appear
(if not, run: open $ARCHIVE_IOS $ARCHIVE_MACOS). Select each in turn → Distribute
App → App Store Connect → Upload. Same tester group covers both platforms once
each build clears export compliance.
EOF
