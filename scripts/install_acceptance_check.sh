#!/bin/bash
# Wait for a freshly installed Dot to launch, then prove it is still running
# after the requested window. Used by the release acceptance jobs, which run on
# a hosted Mac below Dot's minimum: the expected state is the blocking hardware
# refusal alert with the process alive, not a conversation.
#
# Usage: bash scripts/install_acceptance_check.sh [app-path] [alive-seconds]
set -euo pipefail

APP="${1:-$HOME/Applications/Dot.app}"
ALIVE="${2:-60}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -d "$APP" ] || fail "no app at $APP"
[ -x "$APP/Contents/MacOS/Dot" ] || fail "no executable at $APP/Contents/MacOS/Dot"

LAUNCH_DEADLINE=$((SECONDS + 45))
while [ "$SECONDS" -lt "$LAUNCH_DEADLINE" ]; do
    if pgrep -x Dot >/dev/null 2>&1; then break; fi
    sleep 1
done
pgrep -x Dot >/dev/null 2>&1 || fail "Dot did not launch within 45 s"
pass "Dot launched"

START=$SECONDS
ALIVE_DEADLINE=$((START + ALIVE))
while [ "$SECONDS" -lt "$ALIVE_DEADLINE" ]; do
    pgrep -x Dot >/dev/null 2>&1 || fail "Dot exited after $((SECONDS - START))s, before ${ALIVE}s"
    sleep 1
done
pgrep -x Dot >/dev/null 2>&1 || fail "Dot is not running after ${ALIVE}s"
pass "Dot is still running after ${ALIVE}s"
