#!/bin/bash
# Launch the REAL packaged Dot app on a macOS CI runner and capture the
# below-minimum hardware refusal.
#
# This script does not bypass, relax or override the launch gate. A hosted
# runner is below Dot's minimum (M5 Pro class / 48 GB / macOS 27+), so the
# expected outcome is the blocking refusal alert. The script:
#   1. launches build/Dot.app/Contents/MacOS/Dot,
#   2. waits (bounded) for the refusal to be written to the launch log,
#   3. copies the state and console evidence,
#   4. terminates the modal alert rather than leaving a hung process,
#   5. fails unless the exact refusal text and the launch log exist.
#
# Usage: bash scripts/real_app_launch_check.sh [app-path] [output-dir]
set -uo pipefail

APP="${1:-build/Dot.app}"
OUT="${2:-.tmp/real-app-check}"
EXE="$APP/Contents/MacOS/Dot"
SUPPORT="$HOME/Library/Application Support/Dot"
LOG="$SUPPORT/Logs/dot_chat_log.txt"
TRANSCRIPT="$OUT/launch-transcript.txt"
CONSOLE="$OUT/console.log"
STATE="$OUT/state-files.txt"

fail() {
    echo "real_app_launch_check: $*" >&2
    echo "real_app_launch_check: $*" | tee -a "$TRANSCRIPT" >&2
    exit 1
}

[ -x "$EXE" ] || { mkdir -p "$OUT"; : > "$TRANSCRIPT"; fail "no executable at $EXE"; }
mkdir -p "$OUT"
: > "$TRANSCRIPT"
: > "$CONSOLE"
: > "$STATE"

note() { echo "$*" | tee -a "$TRANSCRIPT"; }

note "== real app launch check =="
note "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
note "host arch: $(uname -m)"
note "host OS: $(sw_vers -productVersion 2>/dev/null || uname -r)"
note "host chip: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
note "host RAM bytes: $(sysctl -n hw.memsize 2>/dev/null || echo unknown)"
note "app: $APP"
note "executable: $EXE"
note "support: $SUPPORT"

[ "$(uname -m)" = "arm64" ] || fail "this check requires an arm64 runner (got $(uname -m))"

# Fresh state, so the evidence can only come from this launch.
rm -rf "$SUPPORT"

# Capture crash/console output from the app process, without requiring a grant.
log stream --style compact --predicate 'process == "Dot"' > "$CONSOLE" 2>&1 &
LOG_STREAM_PID=$!

"$EXE" >> "$TRANSCRIPT" 2>&1 &
APP_PID=$!
note "launched pid: $APP_PID"

REFUSED=0
DEADLINE=$((SECONDS + 60))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
    if [ -f "$LOG" ] && grep -qF "Hardware Does Not Meet Dot's Minimum" "$LOG"; then
        REFUSED=1
        note "refusal observed after $((SECONDS - (DEADLINE - 60)))s"
        break
    fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        note "app exited before the refusal log appeared"
        break
    fi
    sleep 1
done

# Capture the durable state before terminating the blocking alert.
{
    echo "support directory: $SUPPORT"
    if [ -d "$SUPPORT" ]; then
        find "$SUPPORT" -maxdepth 4 -print 2>/dev/null | sort
    else
        echo "MISSING: $SUPPORT"
    fi
} > "$STATE"
if [ -f "$LOG" ]; then cp "$LOG" "$OUT/dot_chat_log.txt"; fi

ALIVE=0
if kill -0 "$APP_PID" 2>/dev/null; then
    ALIVE=1
    note "app is alive with the blocking refusal alert; terminating it after evidence capture"
    kill -TERM "$APP_PID" 2>/dev/null || true
    sleep 2
    kill -KILL "$APP_PID" 2>/dev/null || true
fi
wait "$APP_PID" 2>/dev/null
APP_STATUS=$?
note "app exit status: $APP_STATUS (alive_until_terminated=$ALIVE)"

kill "$LOG_STREAM_PID" 2>/dev/null || true
wait "$LOG_STREAM_PID" 2>/dev/null || true

CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
CRASHES="$(find "$CRASH_DIR" -maxdepth 1 -name 'Dot*' -newer "$TRANSCRIPT" -print 2>/dev/null || true)"
if [ -n "$CRASHES" ]; then
    note "crash reports:"
    echo "$CRASHES" | tee -a "$TRANSCRIPT"
fi

note "== launch transcript =="
cat "$TRANSCRIPT"
note "== end launch transcript =="
note "== console log (first 200 lines) =="
sed -n '1,200p' "$CONSOLE" | tee -a "$TRANSCRIPT"
note "== end console log =="
note "== state files =="
cat "$STATE" | tee -a "$TRANSCRIPT"
note "== end state files =="

[ "$REFUSED" -eq 1 ] || fail "the exact below-minimum refusal was not observed within 60s"
[ -f "$LOG" ] || fail "the app did not create its launch log at $LOG"
grep -qF "Hardware Does Not Meet Dot's Minimum" "$LOG" \
    || fail "refusal title missing from the launch log"
grep -qF "Dot needs Apple Silicon M5 Pro class or newer, 48 GB Unified Memory and macOS 27.0 or newer." "$LOG" \
    || fail "the exact minimum specification sentence is missing"
grep -qF "The exact Qwen3.8 27B Q4 model runs locally and has no smaller fallback, so Dot cannot start on this Mac." "$LOG" \
    || fail "the no-fallback sentence is missing"
grep -qF "Not met:" "$LOG" || fail "the detected below-minimum reasons are missing"
grep -qF "Processor (" "$LOG" || fail "the processor reason is missing"
grep -qF "Unified Memory (" "$LOG" || fail "the memory reason is missing"
grep -qF "Operating System (macOS " "$LOG" || fail "the OS reason is missing"
[ -n "$CRASHES" ] && fail "the app produced a crash report"

if [ "$ALIVE" -eq 1 ]; then
    note "PASS: real app started, wrote its launch log, and showed the exact below-minimum refusal; the harness terminated the blocking alert."
    exit 0
fi
if [ "$APP_STATUS" -eq 0 ] || [ "$APP_STATUS" -eq 143 ] || [ "$APP_STATUS" -eq 137 ]; then
    note "PASS: real app started, wrote its launch log, and showed the exact below-minimum refusal (exit $APP_STATUS)."
    exit 0
fi
fail "the app exited unexpectedly (status $APP_STATUS) after the refusal"
