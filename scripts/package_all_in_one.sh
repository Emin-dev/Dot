#!/bin/bash
# Owner-run: publish the all-in-one installer as <2 GiB parts.
#
# Run on the Mac that produced an accepted complete DMG:
#   DOT_ALL_IN_ONE_DMG=build-complete/Dot.dmg bash scripts/package_all_in_one.sh
#
# Requires an authenticated `gh`. Every part is <2 GB, the manifest carries the
# whole and per-part SHA-256, and join-dot-dmg.command downloads/joins/verifies.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DOT_ALL_IN_ONE_DMG:?Set DOT_ALL_IN_ONE_DMG to the accepted complete DMG}"
TAG="${DOT_ALL_IN_ONE_TAG:-all-in-one-v1}"
OUT="${DOT_ALL_IN_ONE_DIR:-build-all-in-one}"
BASE="https://github.com/Emin-dev/Dot/releases/download/$TAG"
[ -f "$DOT_ALL_IN_ONE_DMG" ] || { echo "no DMG at $DOT_ALL_IN_ONE_DMG" >&2; exit 1; }
python3 -B scripts/split_release.py "$DOT_ALL_IN_ONE_DMG" --output "$OUT" \
  --part-size 1900000000 --base-url "$BASE/"
cp packaging/join-dot-dmg.command scripts/join_release.py "$OUT/"
MANIFEST="$(basename "$DOT_ALL_IN_ONE_DMG").parts.json"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$OUT"/* --clobber
else
  gh release create "$TAG" "$OUT"/* --title "Dot all-in-one installer" \
    --notes "Complete offline Dot installer split into <2 GB parts. Download the .parts.json, join-dot-dmg.command and join_release.py, then double-click the command."
fi
echo "published $TAG with $MANIFEST; parts are in $OUT"
