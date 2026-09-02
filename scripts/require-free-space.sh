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

if [[ "$need" == "0" ]]; then
  exit 0
fi

# df -g reports whole gibibytes; column 4 is Available. An unreadable df is not
# a reason to block a build, so a blank read passes.
avail=$(df -g . 2>/dev/null | awk 'NR==2 {print $4}')
if [[ -z "$avail" ]]; then
  exit 0
fi

if (( avail < need )); then
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
