#!/usr/bin/env bash
#
# Fixture suite for the release scripts — archive.sh (testflight-release) and
# release.sh (dmg-release).
#
# Covers the refusals and recovery paths, which is where every regression in
# pupa#297 lived: guards placed after the edit they were meant to precede, traps
# registered inside a conditional, sentinels that never matched. All of it looked
# right in a diff and `bash -n` passed throughout, so this suite runs the scripts.
#
# Hermetic: a synthetic git repo seeded with the real project.pbxproj and
# Version.swift (so the pbxproj awk is exercised against the true file shape),
# and stub `xcodebuild`/`security`/`xcrun`/`gh` on PATH. No network, no Xcode, no
# signing identity, and nothing written outside a temp dir — except
# /tmp/pupa-archive-*.log, which archive.sh writes itself.
#
# Verified against mutations: reverting the trap hoist, the plist sentinel, the
# revert-after-failed-commit, or the dev refusal each turns this suite red.
#
# Not covered: the archive itself, notarization, stapling, and everything in
# release.sh downstream of `xcodebuild archive` — all of it needs a real toolchain
# and a real Developer ID. verify_archive is reached by extracting the function,
# since the script cannot be sourced.
#
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARCHIVE_SH="$REPO_ROOT/.claude/skills/testflight-release/archive.sh"
RELEASE_SH="$REPO_ROOT/.claude/skills/dmg-release/release.sh"
PREFLIGHT_SH="$REPO_ROOT/.claude/skills/ship-release/preflight.sh"
REAL_PBXPROJ="$REPO_ROOT/PupaHost/PupaHost.xcodeproj/project.pbxproj"
REAL_VERSION_SWIFT="$REPO_ROOT/Pupa/Sources/PupaApp/Version.swift"
REAL_FREE_SPACE="$REPO_ROOT/scripts/require-free-space.sh"

PBXPROJ="PupaHost/PupaHost.xcodeproj/project.pbxproj"

# Seeded so assertions never depend on what the real repo happens to be at.
SEED_MV="0.0.100"
SEED_BUILD="200"

TMP=$(mktemp -d -t pupa-release-tests)
FIXTURE="$TMP/repo"
STUBS="$TMP/stubs"
ORIGIN="$TMP/origin.git"
trap 'rm -rf "$TMP"' EXIT

# Isolate from the developer's own git config: a global hooksPath, a signing
# key, or a missing user.name would each make these tests fail for reasons that
# have nothing to do with the scripts.
export GIT_CONFIG_GLOBAL=/dev/null
export PATH="$STUBS:$PATH"
# Cases that care set this themselves; everywhere else the suite must not
# depend on how full the developer's disk happens to be.
export PUPA_MIN_FREE_GB=0
# archive.sh registers its archives with Organizer on success. Launching
# Xcode from a test run is not acceptable.
export PUPA_SKIP_OPEN=1
# Where the gh stub records that a release now exists.
export PUPA_TEST_GH_STATE="$TMP/gh-release-exists"

PASS=0
FAIL=0
CASE=""
CASE_FAILED=0

# --- assertions -----------------------------------------------------------
bad() { CASE_FAILED=1; printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$CASE" "$1"; }

# Last run's exit status, stdout+stderr, captured by `run`.
STATUS=0
OUT=""
run() { OUT=$( "$@" 2>&1 ); STATUS=$?; }

expect_status() {
  [[ $STATUS -eq $1 ]] || bad "expected exit $1, got $STATUS. Output:
       ${OUT//$'\n'/$'\n'       }"
}
expect_out() {
  [[ "$OUT" == *"$1"* ]] || bad "expected output to contain '$1'. Got:
       ${OUT//$'\n'/$'\n'       }"
}
expect_no_out() {
  [[ "$OUT" != *"$1"* ]] || bad "expected output NOT to contain '$1'. Got:
       ${OUT//$'\n'/$'\n'       }"
}
expect_branch() {
  local actual; actual=$(git -C "$FIXTURE" rev-parse --abbrev-ref HEAD)
  [[ "$actual" == "$1" ]] || bad "expected to end on branch '$1', ended on '$actual'"
}
expect_clean_pbxproj() {
  local dirty; dirty=$(git -C "$FIXTURE" status --porcelain -- "$PBXPROJ")
  [[ -z "$dirty" ]] || bad "expected $PBXPROJ untouched, but it is dirty"
}
expect_pbxproj_has() {
  grep -q "$1" "$FIXTURE/$PBXPROJ" || bad "expected pbxproj to contain '$1'"
}

# --- fixture --------------------------------------------------------------
mkdir -p "$STUBS"

# Fails by default, so a run reaches the archive step and then stops — which is
# also the shape the --flow trap has to survive. PUPA_TEST_XCODEBUILD_OK=1
# instead produces a minimal .xcarchive, for the success path.
cat > "$STUBS/xcodebuild" <<'STUB'
#!/usr/bin/env bash
[[ "${PUPA_TEST_XCODEBUILD_OK:-0}" == "1" ]] || { echo "stub xcodebuild: archive failed" >&2; exit 65; }
path=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "-archivePath" ]] && path="$2"
  shift
done
[[ -n "$path" ]] || exit 0
mkdir -p "$path"
/usr/libexec/PlistBuddy -c "Add :ApplicationProperties dict" \
  -c "Add :ApplicationProperties:CFBundleShortVersionString string 0.0.100" \
  -c "Add :ApplicationProperties:CFBundleVersion string 200" \
  -c "Add :ApplicationProperties:CFBundleIdentifier string dev.pupa.Pupa" \
  "$path/Info.plist" >/dev/null
STUB

cat > "$STUBS/security" <<'STUB'
#!/usr/bin/env bash
cat <<'IDS'
  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Test (TEAMID1234)"
  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Test (TEAMID1234)"
  3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "Developer ID Installer: Test (TEAMID1234)"
     3 valid identities found
IDS
STUB

cat > "$STUBS/xcrun" <<'STUB'
#!/usr/bin/env bash
# `stapler validate` is the one xcrun call whose failure a case needs to drive:
# it is how --publish-only tells a notarized DMG from a --skip-notarize one.
if [[ "${PUPA_TEST_STAPLE_BAD:-0}" == "1" && "$*" == *stapler*validate* ]]; then
  echo "stub stapler: no ticket" >&2
  exit 1
fi
exit 0
STUB
cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
# Models the one gh sequence release.sh drives: `release view` fails until a
# `release create` succeeds, and then reports a draft with a URL. A stub that
# answered 0 to everything made every publish look like an attempt to clobber an
# already-published release.
state="${PUPA_TEST_GH_STATE:-/dev/null}"
if [[ "${1:-}" == "release" && "${2:-}" == "create" ]]; then
  [[ "$state" != /dev/null ]] && : > "$state"
  exit 0
fi
if [[ "${1:-}" == "release" && "${2:-}" == "view" ]]; then
  [[ -f "$state" ]] || { echo "release not found" >&2; exit 1; }
  case "$*" in
    *isDraft*) echo "${PUPA_TEST_GH_DRAFT:-true}" ;;
    *url*)     echo "https://example.invalid/releases/tag/v-stub" ;;
  esac
  exit 0
fi
exit 0
STUB
chmod +x "$STUBS"/*

git init -q "$FIXTURE"
cd "$FIXTURE"
git config user.name "fixture"
git config user.email "fixture@example.invalid"
git config commit.gpgsign false
git checkout -q -b main

mkdir -p "PupaHost/PupaHost.xcodeproj" \
         "PupaHost/PupaHost/Assets.xcassets/AppIcon.appiconset" \
         "Pupa/Sources/PupaApp" \
         "scripts"
cp "$REAL_PBXPROJ" "$PBXPROJ"
cp "$REAL_VERSION_SWIFT" "Pupa/Sources/PupaApp/Version.swift"
# Only a precondition checks for it; every case passes --skip-icon-check.
touch "PupaHost/PupaHost/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
printf 'DEVELOPMENT_TEAM = TEAMID1234\n' > "PupaHost/Local.xcconfig"
printf '#!/bin/sh\nexit 0\n' > "scripts/verify-mac-entitlements.sh"
cp "$REAL_FREE_SPACE" "scripts/require-free-space.sh"
chmod +x "scripts/verify-mac-entitlements.sh" "scripts/require-free-space.sh"

# Pin the app target to known numbers. The test targets sit at MARKETING_VERSION
# 1.0 / CURRENT_PROJECT_VERSION 1 and must stay there — one of the cases below
# asserts the bump did not reach them.
sed -i '' -E "s/MARKETING_VERSION = 0\.0\.[0-9]+;/MARKETING_VERSION = $SEED_MV;/g" "$PBXPROJ"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]{2,};/CURRENT_PROJECT_VERSION = $SEED_BUILD;/g" "$PBXPROJ"

cat > CHANGELOG.md <<EOF
# Changelog

## [$SEED_MV] — 2026-01-01

### Fixed

- A seeded entry, so the notes are not blank.

## [0.0.99] — 2025-12-31
EOF

git add -A
git commit -q -m "fixture baseline"
git tag baseline
git branch -f dev baseline

# Guard the seed itself: if the real pbxproj ever stops matching these patterns,
# every case below would pass vacuously against an unpinned file.
grep -q "MARKETING_VERSION = $SEED_MV;" "$PBXPROJ" || { echo "seed failed: app MARKETING_VERSION not pinned" >&2; exit 1; }
grep -q "CURRENT_PROJECT_VERSION = $SEED_BUILD;" "$PBXPROJ" || { echo "seed failed: app CURRENT_PROJECT_VERSION not pinned" >&2; exit 1; }
grep -q "CURRENT_PROJECT_VERSION = 1;" "$PBXPROJ" || { echo "seed failed: test targets no longer at build 1" >&2; exit 1; }

# --- per-case setup -------------------------------------------------------
# `synced`: PupaAppVersion equals the pbxproj MARKETING_VERSION, so with
# --no-bump there is nothing to commit. `drift`: they differ, so a commit is
# needed even under --no-bump — the case the refusals exist for.
reset() {
  local mode="${1:-synced}" version="$SEED_MV"
  [[ "$mode" == "drift" ]] && version="0.0.101"
  cd "$FIXTURE"
  git checkout -q --detach baseline
  git reset -q --hard baseline
  git clean -qfd >/dev/null 2>&1
  rm -f .git/hooks/pre-commit
  git branch -f dev baseline
  git branch -f main baseline
  git checkout -q -B feature baseline
  if [[ "$version" != "$SEED_MV" ]]; then
    sed -i '' -E "s/PupaAppVersion: String = \"[^\"]*\"/PupaAppVersion: String = \"$version\"/" Pupa/Sources/PupaApp/Version.swift
  else
    sed -i '' -E "s/PupaAppVersion: String = \"[^\"]*\"/PupaAppVersion: String = \"$SEED_MV\"/" Pupa/Sources/PupaApp/Version.swift
  fi
  git commit -q -am "fixture: PupaAppVersion $version"
  git branch -f dev HEAD
  git branch -f main HEAD
  unset PUPA_TEST_XCODEBUILD_OK
  unset PUPA_TEST_STAPLE_BAD
  unset PUPA_TEST_GH_DRAFT
  rm -f "$PUPA_TEST_GH_STATE"
}

case_start() { CASE="$1"; CASE_FAILED=0; }
case_end() {
  if [[ $CASE_FAILED -eq 0 ]]; then
    PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$CASE"
  else
    FAIL=$((FAIL + 1))
  fi
}

echo
echo "archive.sh — refusing the bump commit"

for target in "detached HEAD:--detach HEAD:HEAD" "main:main:main" "dev without --flow:dev:dev"; do
  IFS=: read -r label checkout named <<< "$target"
  case_start "refuses on $label, leaving pbxproj untouched"
  reset drift
  git checkout -q $checkout
  run "$ARCHIVE_SH" --no-bump --skip-icon-check
  expect_status 1
  expect_out "Refusing to change"
  expect_out "on '$named'"
  expect_out "MARKETING_VERSION $SEED_MV → 0.0.101"
  expect_clean_pbxproj
  case_end
done

case_start "refusal names the build bump and offers --no-bump when that would help"
reset synced
git checkout -q main
run "$ARCHIVE_SH" --skip-icon-check
expect_status 1
expect_out "CURRENT_PROJECT_VERSION $SEED_BUILD → 201"
expect_out "Or pass --no-bump"
expect_no_out "MARKETING_VERSION"
case_end

case_start "refusal does not offer --no-bump when the operator already passed it"
reset drift
git checkout -q main
run "$ARCHIVE_SH" --no-bump --skip-icon-check
expect_status 1
expect_no_out "Or pass --no-bump"
case_end

echo
echo "archive.sh — committing the bump where it is allowed"

case_start "commits on a feature branch, app target only"
reset synced
run "$ARCHIVE_SH" --skip-icon-check
expect_status 1                    # the stub archive fails; the commit is the subject here
expect_out "bumped CURRENT_PROJECT_VERSION $SEED_BUILD → 201"
[[ "$(git log -1 --pretty=%s)" == "chore(ios): bump build to 201" ]] \
  || bad "commit subject was '$(git log -1 --pretty=%s)'"
expect_pbxproj_has "CURRENT_PROJECT_VERSION = 201;"
expect_pbxproj_has "CURRENT_PROJECT_VERSION = 1;"   # test targets untouched
case_end

case_start "commit subject names both changes when both are pending"
reset drift
run "$ARCHIVE_SH" --skip-icon-check
[[ "$(git log -1 --pretty=%s)" == "chore(ios): bump build to 201, sync MARKETING_VERSION to 0.0.101" ]] \
  || bad "commit subject was '$(git log -1 --pretty=%s)'"
case_end

case_start "commit subject names only the sync under --no-bump"
reset drift
run "$ARCHIVE_SH" --no-bump --skip-icon-check
[[ "$(git log -1 --pretty=%s)" == "chore(ios): sync MARKETING_VERSION to 0.0.101" ]] \
  || bad "commit subject was '$(git log -1 --pretty=%s)'"
case_end

case_start "--flow permits the commit on dev"
reset drift
git checkout -q dev
run "$ARCHIVE_SH" --no-bump --skip-icon-check --flow
expect_no_out "Refusing to change"
case_end

echo
echo "archive.sh — the operator's own pbxproj edits"

case_start "absorb guard refuses and preserves the user's edit"
reset synced
printf '\n// user edit\n' >> "$PBXPROJ"
run "$ARCHIVE_SH" --skip-icon-check
expect_status 1
expect_out "The bump commit would absorb them"
[[ "$(tail -1 "$PBXPROJ")" == "// user edit" ]] || bad "the user's pbxproj edit was lost"
expect_no_out "bumped CURRENT_PROJECT_VERSION"
case_end

case_start "warns rather than refuses when nothing needs committing"
reset synced
printf '\n// user edit\n' >> "$PBXPROJ"
run "$ARCHIVE_SH" --no-bump --skip-icon-check
expect_out "has uncommitted changes; the archive will carry them"
expect_no_out "Refusing to change"
case_end

case_start "no warning on a clean tree with nothing to commit"
reset synced
run "$ARCHIVE_SH" --no-bump --skip-icon-check
expect_no_out "has uncommitted changes"
case_end

case_start "refuses a tree dirty outside pbxproj"
reset synced
printf 'stray\n' > stray.txt
git add stray.txt
run "$ARCHIVE_SH" --no-bump --skip-icon-check
expect_status 1
expect_out "Commit or stash these before archiving"
case_end

echo
echo "archive.sh — recovery when the commit is rejected"

case_start "a rejecting pre-commit hook leaves no bump behind"
reset synced
printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
run "$ARCHIVE_SH" --skip-icon-check
expect_status 1
expect_out "the bump was reverted"
[[ -z "$(git status --porcelain)" ]] || bad "tree is dirty after the failed commit:
       $(git status --porcelain)"
[[ -z "$(git diff --cached --name-only)" ]] || bad "changes left staged after the failed commit"
case_end

echo
echo "archive.sh — the --flow branch trap"

case_start "--flow failing from dev ends back on dev"
reset synced
git checkout -q dev
run "$ARCHIVE_SH" --no-bump --skip-icon-check --flow
expect_status 1
expect_branch "dev"
case_end

case_start "--flow failing from a feature branch ends back on it"
reset synced
run "$ARCHIVE_SH" --no-bump --skip-icon-check --flow
expect_status 1
expect_branch "feature"
case_end

case_start "a successful --flow is left on main"
reset synced
export PUPA_TEST_XCODEBUILD_OK=1
run "$ARCHIVE_SH" --no-bump --skip-icon-check --flow
unset PUPA_TEST_XCODEBUILD_OK
expect_status 0
expect_out "ARCHIVES READY"
expect_branch "main"
case_end

case_start "without --flow, main and dev do not move"
reset synced
MAIN_BEFORE=$(git rev-parse main)
export PUPA_TEST_XCODEBUILD_OK=1
run "$ARCHIVE_SH" --skip-icon-check
unset PUPA_TEST_XCODEBUILD_OK
[[ "$(git rev-parse main)" == "$MAIN_BEFORE" ]] || bad "main moved without --flow"
expect_branch "feature"
case_end

echo
echo "archive.sh — flags and archive integrity"

case_start "--build rejects a non-integer"
reset synced
run "$ARCHIVE_SH" --build abc --skip-icon-check
expect_status 1
expect_out "--build must be a positive integer"
case_end

case_start "--build rejects a value that does not exceed the current build"
reset synced
run "$ARCHIVE_SH" --build "$SEED_BUILD" --skip-icon-check
expect_status 1
expect_out "does not exceed the current build"
case_end

case_start "--no-flow is no longer accepted"
reset synced
run "$ARCHIVE_SH" --no-flow --skip-icon-check
expect_status 2
expect_out "unknown flag: --no-flow"
case_end

echo
echo "both scripts — the signing team guard"

# Config.xcconfig includes Local.xcconfig with `#include?`, so a checkout
# without it configures and only fails inside xcodebuild, minutes later, with a
# message naming the project rather than the missing file. `reset` restores the
# fixture's copy, so each case may delete or rewrite it freely.
#
# The empty-value case is the regression: the old `grep | sed` read let a
# substitution that did not match pass the whole line through, so
# 'DEVELOPMENT_TEAM =' tested non-empty and reached release.sh's export plist as
# a teamID of "DEVELOPMENT_TEAM =".
LOCAL_XCCONFIG="PupaHost/Local.xcconfig"

case_start "archive.sh refuses when Local.xcconfig is absent"
reset synced
rm -f "$LOCAL_XCCONFIG"
run "$ARCHIVE_SH" --no-bump --skip-icon-check
expect_status 1
expect_out "no signing team"
expect_out "$LOCAL_XCCONFIG.example"
case_end

case_start "archive.sh refuses an empty DEVELOPMENT_TEAM"
reset synced
printf 'DEVELOPMENT_TEAM = \n' > "$LOCAL_XCCONFIG"
run "$ARCHIVE_SH" --no-bump --skip-icon-check
expect_status 1
expect_out "sets no DEVELOPMENT_TEAM"
case_end

case_start "archive.sh refuses the placeholder team id"
reset synced
printf 'DEVELOPMENT_TEAM = YOURTEAMID\n' > "$LOCAL_XCCONFIG"
run "$ARCHIVE_SH" --no-bump --skip-icon-check
expect_status 1
expect_out "still holds the placeholder"
case_end

# The point of the guard is that it lands before the slow, mutating part. If it
# ever slipped below the bump, this is what would catch it.
case_start "archive.sh's guard fires before the bump touches pbxproj"
reset synced
rm -f "$LOCAL_XCCONFIG"
run "$ARCHIVE_SH" --skip-icon-check
expect_status 1
expect_out "no signing team"
expect_no_out "bumped CURRENT_PROJECT_VERSION"
expect_clean_pbxproj
case_end

case_start "release.sh refuses when Local.xcconfig is absent"
reset synced
rm -f "$LOCAL_XCCONFIG"
run "$RELEASE_SH" --skip-notarize
expect_status 1
expect_out "no signing team"
case_end

case_start "release.sh refuses an empty DEVELOPMENT_TEAM"
reset synced
printf 'DEVELOPMENT_TEAM = \n' > "$LOCAL_XCCONFIG"
run "$RELEASE_SH" --skip-notarize
expect_status 1
expect_out "sets no DEVELOPMENT_TEAM"
case_end

# verify_archive cannot be reached without a real archive, and archive.sh is not
# sourceable — it runs top to bottom. Extracting the function is the only way to
# exercise it, and it is worth exercising: the `$(cmd || echo '?')` shape it used
# to carry let a malformed archive print under "ARCHIVES READY" and exit 0.
# Extracted to a driver script rather than sourced: archive.sh runs top to bottom
# and cannot be sourced without executing a release.
VERIFY_DRIVER="$TMP/verify_archive_driver.sh"
{
  printf 'set -euo pipefail\n'
  printf 'die() { echo "error: $*" >&2; exit 1; }\n'
  awk '/^verify_archive\(\) \{/,/^\}/' "$ARCHIVE_SH"
  printf 'verify_archive "$1"\n'
} > "$VERIFY_DRIVER"
grep -q 'PlistBuddy' "$VERIFY_DRIVER" || { echo "extraction of verify_archive failed" >&2; exit 1; }

verify_archive_case() {
  local desc="$1" dir="$2" want_status="$3" want_out="$4"
  case_start "verify_archive: $desc"
  run bash "$VERIFY_DRIVER" "$dir"
  expect_status "$want_status"
  expect_out "$want_out"
  case_end
}

mkdir -p "$TMP/corrupt.xcarchive" "$TMP/empty.xcarchive" "$TMP/good.xcarchive"
printf '%%not a plist%%' > "$TMP/corrupt.xcarchive/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ApplicationProperties dict" \
  -c "Add :ApplicationProperties:CFBundleShortVersionString string 0.0.100" \
  -c "Add :ApplicationProperties:CFBundleVersion string 200" \
  -c "Add :ApplicationProperties:CFBundleIdentifier string dev.pupa.Pupa" \
  "$TMP/good.xcarchive/Info.plist" >/dev/null

verify_archive_case "a corrupt Info.plist is fatal" "$TMP/corrupt.xcarchive" 1 "the archive is malformed"
verify_archive_case "a missing Info.plist is fatal" "$TMP/empty.xcarchive"   1 "No Info.plist"
verify_archive_case "a good archive reports its fields" "$TMP/good.xcarchive" 0 "0.0.100|200|dev.pupa.Pupa"

echo
echo "release.sh — --publish preconditions"

publish_setup() {
  reset synced
  export NOTARY_PROFILE=fixture
}

case_start "--publish is refused alongside --skip-notarize"
publish_setup
run "$RELEASE_SH" --publish --skip-notarize
expect_status 1
expect_out "cannot be combined with --skip-notarize"
case_end

case_start "--publish is refused for a development-signed build"
publish_setup
run "$RELEASE_SH" --publish --development-signing
expect_status 1
expect_out "cannot be combined with --skip-notarize"
case_end

case_start "--publish reports an unreachable origin as such, not as a missing tag"
publish_setup
git remote remove origin 2>/dev/null
git remote add origin "$TMP/does-not-exist.git"
run "$RELEASE_SH" --publish
expect_status 1
expect_out "Could not reach origin"
expect_no_out "does not exist on origin"
case_end

git init -q --bare "$ORIGIN"

case_start "--publish refuses when the tag is not on origin"
publish_setup
git remote remove origin 2>/dev/null
git remote add origin "$ORIGIN"
run "$RELEASE_SH" --publish
expect_status 1
expect_out "Tag v$SEED_MV does not exist on origin"
case_end

case_start "--publish refuses when the CHANGELOG section is empty"
publish_setup
git remote remove origin 2>/dev/null
git remote add origin "$ORIGIN"
git tag -f "v$SEED_MV" >/dev/null
git push -q --force origin "refs/tags/v$SEED_MV"
printf '# Changelog\n\n## [%s] — 2026-01-01\n\n## [0.0.99] — 2025-12-31\n' "$SEED_MV" > CHANGELOG.md
git commit -q -am "fixture: empty CHANGELOG section"
run "$RELEASE_SH" --publish
expect_status 1
expect_out "CHANGELOG has no non-empty section"
case_end

case_start "--publish accepts a tagged version with real notes"
publish_setup
git remote remove origin 2>/dev/null
git remote add origin "$ORIGIN"
git tag -f "v$SEED_MV" >/dev/null
git push -q --force origin "refs/tags/v$SEED_MV"
run "$RELEASE_SH" --publish
expect_no_out "does not exist on origin"
expect_no_out "CHANGELOG has no non-empty section"
expect_out "building Pupa $SEED_MV"
case_end

echo
echo "free space — refusing before the expensive part"

case_start "archive.sh refuses when the disk cannot hold both archives"
reset synced
run env PUPA_MIN_FREE_GB=999999 "$ARCHIVE_SH" --no-bump --skip-icon-check
expect_status 1
expect_out "999999G needed for"
case_end

# The guard used to sit below the bump, so a refusal still committed. --no-bump
# above hides that; this case is the one that catches it.
case_start "the free-space refusal leaves pbxproj and the branch untouched"
reset drift
run env PUPA_MIN_FREE_GB=999999 "$ARCHIVE_SH" --skip-icon-check
expect_status 1
expect_out "999999G needed for"
expect_no_out "bumped CURRENT_PROJECT_VERSION"
expect_no_out "committed pbxproj"
expect_clean_pbxproj
case_end

case_start "a --flow free-space refusal does not fast-forward main"
reset drift
MAIN_BEFORE=$(git rev-parse main)
run env PUPA_MIN_FREE_GB=999999 "$ARCHIVE_SH" --skip-icon-check --flow
expect_status 1
[[ "$(git rev-parse main)" == "$MAIN_BEFORE" ]] || bad "main moved despite the refusal"
expect_clean_pbxproj
case_end

case_start "the archive summary does not both claim and deny registration"
reset synced
run env PUPA_TEST_XCODEBUILD_OK=1 "$ARCHIVE_SH" --no-bump --skip-icon-check
expect_status 0
expect_out "Register them with Xcode first"
expect_no_out "registered with Xcode already"
case_end

case_start "release.sh refuses when the disk cannot hold the archive and DMG"
reset synced
export NOTARY_PROFILE=fixture
run env PUPA_MIN_FREE_GB=999999 "$RELEASE_SH"
expect_status 1
expect_out "999999G needed for"
case_end

case_start "the free-space check does not run the archive first"
reset synced
export NOTARY_PROFILE=fixture
run env PUPA_MIN_FREE_GB=999999 "$RELEASE_SH"
expect_no_out "archiving macOS"
case_end

echo
echo "release.sh — --publish-only"

case_start "--publish-only refuses when build/ holds no DMG"
publish_setup
git remote remove origin 2>/dev/null
git remote add origin "$ORIGIN"
git tag -f "v$SEED_MV" >/dev/null
git push -q --force origin "refs/tags/v$SEED_MV"
rm -f "build/Pupa-$SEED_MV.dmg"
run "$RELEASE_SH" --publish-only
expect_status 1
expect_out "found no DMG"
case_end

case_start "--publish-only refuses a DMG with no stapled ticket"
publish_setup
git remote remove origin 2>/dev/null
git remote add origin "$ORIGIN"
git tag -f "v$SEED_MV" >/dev/null
git push -q --force origin "refs/tags/v$SEED_MV"
mkdir -p build
touch "build/Pupa-$SEED_MV.dmg"
run env PUPA_TEST_STAPLE_BAD=1 "$RELEASE_SH" --publish-only
expect_status 1
expect_out "no stapled notarization ticket"
case_end

case_start "--publish-only publishes without archiving"
publish_setup
git remote remove origin 2>/dev/null
git remote add origin "$ORIGIN"
git tag -f "v$SEED_MV" >/dev/null
git push -q --force origin "refs/tags/v$SEED_MV"
mkdir -p build
touch "build/Pupa-$SEED_MV.dmg"
run "$RELEASE_SH" --publish-only
expect_status 0
expect_out "nothing rebuilt"
expect_no_out "archiving macOS"
case_end

case_start "--publish-only does not demand a notary profile it never uses"
publish_setup
unset NOTARY_PROFILE
git remote remove origin 2>/dev/null
git remote add origin "$ORIGIN"
git tag -f "v$SEED_MV" >/dev/null
git push -q --force origin "refs/tags/v$SEED_MV"
mkdir -p build
touch "build/Pupa-$SEED_MV.dmg"
run "$RELEASE_SH" --publish-only
expect_status 0
expect_no_out "No notarytool profile"
case_end

case_start "--publish-only refuses to replace the asset on a published release"
publish_setup
git remote remove origin 2>/dev/null
git remote add origin "$ORIGIN"
git tag -f "v$SEED_MV" >/dev/null
git push -q --force origin "refs/tags/v$SEED_MV"
mkdir -p build
touch "build/Pupa-$SEED_MV.dmg"
: > "$PUPA_TEST_GH_STATE"
run env PUPA_TEST_GH_DRAFT=false "$RELEASE_SH" --publish-only
expect_status 1
expect_out "already published"
case_end

case_start "--publish-only is still refused alongside --skip-notarize"
publish_setup
run "$RELEASE_SH" --publish-only --skip-notarize
expect_status 1
expect_out "cannot be combined with --skip-notarize"
case_end

echo
echo "release.sh — notary profile discovery"

case_start "the notary profile is read from Local.xcconfig when no flag is given"
reset synced
unset NOTARY_PROFILE
printf 'DEVELOPMENT_TEAM = TEAMID1234\nNOTARY_PROFILE = from-xcconfig\n' > "PupaHost/Local.xcconfig"
run "$RELEASE_SH"
expect_no_out "No notarytool profile"
case_end

case_start "a missing profile names all three places it can come from"
reset synced
unset NOTARY_PROFILE
run "$RELEASE_SH"
expect_status 1
expect_out "No notarytool profile"
expect_out "Local.xcconfig"
case_end

echo
echo "ship-release/preflight.sh"

case_start "preflight reports MARKETING_VERSION drift as the release PR's job"
reset drift
run env PUPA_PREFLIGHT_OFFLINE=1 PUPA_MIN_FREE_GB=0 "$PREFLIGHT_SH"
expect_status 1
expect_out "MARKETING_VERSION is"
case_end

case_start "preflight passes a synced checkout"
reset synced
printf 'DEVELOPMENT_TEAM = TEAMID1234\nNOTARY_PROFILE = fixture-profile\n' > "PupaHost/Local.xcconfig"
run env PUPA_PREFLIGHT_OFFLINE=1 PUPA_MIN_FREE_GB=0 "$PREFLIGHT_SH"
expect_status 0
expect_out "clear to ship"
case_end

# A charset-restricted reader truncated at the first space and reported a name
# the user never typed — which then failed at notarytool, after the archive.
case_start "preflight reports a profile name containing spaces intact"
reset synced
printf 'DEVELOPMENT_TEAM = TEAMID1234\nNOTARY_PROFILE = pupa notary 2026\n' > "PupaHost/Local.xcconfig"
run env PUPA_PREFLIGHT_OFFLINE=1 PUPA_MIN_FREE_GB=0 "$PREFLIGHT_SH"
expect_out "profile 'pupa notary 2026' (not checked"
case_end

case_start "preflight does not read a commented-out profile line"
reset synced
printf 'DEVELOPMENT_TEAM = TEAMID1234\n// NOTARY_PROFILE = commented-out\n' > "PupaHost/Local.xcconfig"
run env PUPA_PREFLIGHT_OFFLINE=1 PUPA_MIN_FREE_GB=0 "$PREFLIGHT_SH"
expect_status 1
expect_out "no notarytool profile name"
case_end

case_start "preflight refuses an unknown flag rather than reporting clear to ship"
reset synced
# Without this the checkout still fails another check and the case passes for
# the wrong reason: the point is that a typo must not print "clear to ship".
printf 'DEVELOPMENT_TEAM = TEAMID1234\nNOTARY_PROFILE = fixture-profile\n' > "PupaHost/Local.xcconfig"
run env PUPA_PREFLIGHT_OFFLINE=1 PUPA_MIN_FREE_GB=0 "$PREFLIGHT_SH" --publsh
expect_status 2
expect_out "unknown flag"
expect_no_out "clear to ship"
case_end

case_start "preflight prints usage for --help rather than refusing it"
reset synced
run env PUPA_PREFLIGHT_OFFLINE=1 "$PREFLIGHT_SH" --help
expect_status 0
expect_out "usage:"
case_end

case_start "preflight refuses an unreadable Version.swift instead of reporting a blank version"
reset synced
: > "Pupa/Sources/PupaApp/Version.swift"
run env PUPA_PREFLIGHT_OFFLINE=1 PUPA_MIN_FREE_GB=0 "$PREFLIGHT_SH"
expect_status 2
expect_out "could not read PupaAppVersion"
case_end

case_start "preflight distinguishes a malformed PUPA_MIN_FREE_GB from a full disk"
reset synced
printf 'DEVELOPMENT_TEAM = TEAMID1234\nNOTARY_PROFILE = fixture-profile\n' > "PupaHost/Local.xcconfig"
run env PUPA_PREFLIGHT_OFFLINE=1 PUPA_MIN_FREE_GB=twelve "$PREFLIGHT_SH"
expect_status 1
expect_out "PUPA_MIN_FREE_GB is not a usable value"
expect_no_out "not enough free disk"
case_end

case_start "preflight --publish reports a tag that is not on origin"
reset synced
printf 'DEVELOPMENT_TEAM = TEAMID1234\nNOTARY_PROFILE = fixture-profile\n' > "PupaHost/Local.xcconfig"
git remote remove origin 2>/dev/null
git remote add origin "$ORIGIN"
git push -q --force --delete origin "refs/tags/v$SEED_MV" 2>/dev/null
run env PUPA_PREFLIGHT_OFFLINE=1 PUPA_MIN_FREE_GB=0 "$PREFLIGHT_SH" --publish
expect_status 1
expect_out "is not on origin"
case_end

echo
if [[ $FAIL -eq 0 ]]; then
  printf '\033[32m%d passed\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[31m%d failed\033[0m, %d passed\n' "$FAIL" "$PASS"
exit 1
