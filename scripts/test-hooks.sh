#!/usr/bin/env bash
#
# Fixture suite for scripts/hooks/pre-commit.
#
# A hook that silently passes is worse than no hook, and nothing about reading
# one tells you whether it fires: pupa#297 was a whole PR of guards that looked
# right in a diff and never ran. So this suite stages real content into a real
# git repo and runs the real hook, asserting the exit code each time.
#
# Hermetic: a temp repo seeded with the repo's own .gitleaks.toml, so the
# allowlists under test are the shipped ones. No network. Nothing written
# outside the temp dir.
#
# Verified against mutations: dropping either guard from the hook, or either
# custom rule from .gitleaks.toml, turns this suite red.
#
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="$REPO_ROOT/scripts/hooks/pre-commit"
CONFIG="$REPO_ROOT/.gitleaks.toml"

TMP=$(mktemp -d -t pupa-hook-tests)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# Assemble the forbidden strings at runtime. Written literally, this file would
# be a repo that ships a personal email and a home path — exactly what it exists
# to prevent, and the full-history scan would flag it forever.
EMAIL="someone@""gmail.com"
HOMEPATH="/Users/""somedev/pupa"
# A GitHub PAT shape. Deliberately not an AWS key: gitleaks allowlists AWS's
# own AKIAIOSFODNN7EXAMPLE, and its AWS rule is context-sensitive enough that
# `aws_access_key_id = AKIA...` goes undetected while `token = AKIA...` is
# caught. A ghp_ token is flagged either way, so the assertion means something.
TOKEN="ghp_""0123456789abcdefghijABCDEFGHIJ012345"

setup_repo() {
  rm -rf "$TMP/repo"
  mkdir -p "$TMP/repo/PupaHost/PupaHost.xcodeproj"
  cd "$TMP/repo" || exit 1
  git init -q .
  git config user.email "fixture@pupa-app.com"
  git config user.name "fixture"
  cp "$CONFIG" .gitleaks.toml
  echo "seed" > seed.txt
  git add -A
  git commit -qm "seed"
}

# run_hook <description> <expected exit> [env prefix...]
run_hook() {
  local desc="$1" want="$2"; shift 2
  local out rc
  out=$("$@" sh "$HOOK" 2>&1); rc=$?
  if [[ "$rc" == "$want" ]]; then
    PASS=$((PASS + 1)); echo "  ok   — $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL — $desc (wanted exit $want, got $rc)"
    echo "$out" | sed 's/^/         /'
  fi
}

echo "pre-commit hook fixture suite"

# --- the signing guard -------------------------------------------------------

setup_repo
printf 'buildSettings = {\n\tDEVELOPMENT_TEAM = ABCD123456;\n};\n' \
  > PupaHost/PupaHost.xcodeproj/project.pbxproj
git add -A
run_hook "refuses a non-empty DEVELOPMENT_TEAM in project.pbxproj" 1 env

setup_repo
printf 'buildSettings = {\n\tDEVELOPMENT_TEAM = "";\n};\n' \
  > PupaHost/PupaHost.xcodeproj/project.pbxproj
git add -A
run_hook "allows an empty DEVELOPMENT_TEAM" 0 env

# --- the secret + PII scan ---------------------------------------------------

setup_repo
echo "contact: $EMAIL" > docs.md
git add -A
run_hook "refuses a personal email address" 1 env

setup_repo
echo "contact: support@pupa-app.com" > docs.md
git add -A
run_hook "allows a project contact address" 0 env

setup_repo
echo "commit by pupa-app@users.noreply.github.com" > docs.md
git add -A
run_hook "allows a github noreply address" 0 env

setup_repo
echo "see $HOMEPATH/README.md" > docs.md
git add -A
run_hook "refuses an absolute /Users path" 1 env

setup_repo
echo "api_token = $TOKEN" > creds.txt
git add -A
run_hook "refuses a credential the default ruleset knows" 1 env

setup_repo
echo "nothing to see" > docs.md
git add -A
run_hook "allows a clean staged diff" 0 env

# --- degraded mode -----------------------------------------------------------
# No gitleaks on PATH: warn and let the commit through, rather than blocking
# every contributor who hasn't installed it. The signing guard still applies.

setup_repo
echo "contact: $EMAIL" > docs.md
git add -A
run_hook "passes with a warning when gitleaks is absent" 0 env PATH=/usr/bin:/bin

setup_repo
printf 'DEVELOPMENT_TEAM = ABCD123456;\n' \
  > PupaHost/PupaHost.xcodeproj/project.pbxproj
git add -A
run_hook "still refuses DEVELOPMENT_TEAM when gitleaks is absent" 1 env PATH=/usr/bin:/bin

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
