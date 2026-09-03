#!/usr/bin/env bash
#
# Refuse to start a long build that cannot finish.
#
# Both release channels archive into build/. An archive that runs the disk to
# zero fails five to eight minutes in — after the expensive part — and a disk at
# zero takes down more than the build: every tool that wants a temp file starts
# failing too. One df call up front costs nothing and fails in the first second.
#
# usage: require-free-space.sh <gb-needed> [label]
#
# PUPA_MIN_FREE_GB overrides the requirement. Set it to 0 to skip the check.
set -euo pipefail

need=${PUPA_MIN_FREE_GB:-${1:?usage: require-free-space.sh <gb-needed> [label]}}
label=${2:-this build}

# Validated, not assumed. `(( avail < need ))` returns 1 on an arithmetic error,
# which the `if` below reads as "enough room" — so a typo in PUPA_MIN_FREE_GB
# would silently switch the guard off rather than fail loudly. It is a
# documented user-facing knob, so it gets a real parse.
if ! [[ "$need" =~ ^[0-9]+$ ]]; then
  echo "error: PUPA_MIN_FREE_GB must be a whole number of gibibytes (got '$need')." >&2
  exit 2
fi

if [[ "$need" == "0" ]]; then
  exit 0
fi

# df -g reports whole gibibytes; column 4 is Available. An unreadable df is not
# a reason to block a build — but the assignment must not be allowed to fail the
# script under `set -e` before the emptiness check below runs, which is what a
# bare `avail=$(...)` would do, and silently: the caller would die with no
# message at all.
avail=$(df -g . 2>/dev/null | awk 'NR==2 {print $4}') || avail=""
if ! [[ "$avail" =~ ^[0-9]+$ ]]; then
  exit 0
fi

# 10# forces base 10: bash reads a leading-zero literal as octal, so a value
# like 08 is an arithmetic error, and an error in (( )) reads as "enough room".
if (( 10#$avail < 10#$need )); then
  cat >&2 <<EOF
error: ${avail}G free — ${need}G needed for ${label}.
       Free space before starting. An archive that fills the disk fails after
       the slow part, and a disk at zero breaks far more than this build.
       The usual offenders, largest first:
         rm -rf ~/Library/Developer/Xcode/iOS\ DeviceSupport/*
         xcrun simctl delete unavailable
         rm -rf ~/Library/Developer/Xcode/DerivedData/*
       All three are regenerable caches. Override with PUPA_MIN_FREE_GB=0.
EOF
  exit 1
fi
