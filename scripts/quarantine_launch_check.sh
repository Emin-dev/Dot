#!/bin/bash
# Install the app from the packaged DMG, mark it quarantined like a browser
# download, and prove it still starts and stays alive for 60 s.
#
# The owner's real first open uses Finder > right-click > Open (or System
# Settings > Privacy & Security > Open Anyway, or the documented xattr
# command). A hosted runner cannot click those dialogs, so this check launches
# the executable directly with com.apple.quarantine present. That is the
# strongest automated evidence available without the owner's Mac; the dialog
# interaction itself stays in docs/TEST_TODAY.md.
#
# Usage: bash scripts/quarantine_launch_check.sh <Dot.dmg> [output-dir]
set -euo pipefail

DMG="${1:?usage: quarantine_launch_check.sh <Dot.dmg> [output-dir]}"
OUT="${2:-.tmp/quarantine-check}"
MNT="$OUT/mnt"
INSTALL="$OUT/Applications"
APP="$INSTALL/Dot.app"

[ -f "$DMG" ] || { echo "quarantine_launch_check: no DMG at $DMG" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$MNT" "$INSTALL"

cleanup() { hdiutil detach "$MNT" >/dev/null 2>&1 || true; }
trap cleanup EXIT
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT"
[ -d "$MNT/Dot.app" ] || { echo "quarantine_launch_check: Dot.app missing from $DMG" >&2; exit 1; }
/usr/bin/ditto "$MNT/Dot.app" "$APP"
cleanup
trap - EXIT

STAMP="$(printf '%x' "$(date +%s)")"
/usr/bin/xattr -w com.apple.quarantine "0081;$STAMP;Safari;" "$APP"
ATTR="$(/usr/bin/xattr -p com.apple.quarantine "$APP" 2>/dev/null || true)"
[ -n "$ATTR" ] || { echo "quarantine_launch_check: quarantine attribute was not set" >&2; exit 1; }
echo "quarantine_launch_check: installed $APP with com.apple.quarantine=$ATTR"

DOT_REQUIRE_QUARANTINE=1 DOT_MINIMUM_ALIVE_SECONDS=60 \
    bash scripts/real_app_launch_check.sh "$APP" "$OUT/launch"
