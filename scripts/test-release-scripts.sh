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
REAL_PBXPROJ="$REPO_ROOT/PupaHost/PupaHost.xcodeproj/project.pbxproj"
REAL_VERSION_SWIFT="$REPO_ROOT/Pupa/Sources/PupaApp/Version.swift"

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

printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/xcrun"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/gh"
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
chmod +x "scripts/verify-mac-entitlements.sh"

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
if [[ $FAIL -eq 0 ]]; then
  printf '\033[32m%d passed\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[31m%d failed\033[0m, %d passed\n' "$FAIL" "$PASS"
exit 1
