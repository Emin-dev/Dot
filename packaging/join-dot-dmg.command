#!/bin/bash
# Double-click joiner for the all-in-one Dot DMG.
#
# Put this file, join_release.py and Dot-all-in-one.dmg.parts.json in one folder.
# The script downloads any missing parts, verifies every part and the joined DMG
# by SHA-256, mounts nothing, and then opens the verified DMG.
set -euo pipefail
cd "$(dirname "$0")"

MANIFESTS=(*.parts.json)
if [ ! -e "${MANIFESTS[0]}" ]; then
    echo "Missing a *.parts.json next to this script."
    echo "Download the .parts.json, join_release.py and all part files from the release."
    read -r -p "Press Return to close." _
    exit 1
fi
if [ "${#MANIFESTS[@]}" -gt 1 ]; then
    # Picking one silently could join an older, still-published part set.
    echo "Multiple *.parts.json files are present; remove all but one before joining:" >&2
    printf '  %s\n' "${MANIFESTS[@]}" >&2
    read -r -p "Press Return to close." _
    exit 1
fi
MANIFEST="${MANIFESTS[0]}"

PYTHON="$(command -v python3 || true)"
if [ -z "$PYTHON" ] && [ -x /usr/bin/python3 ]; then PYTHON=/usr/bin/python3; fi
if [ -z "$PYTHON" ]; then
    echo "python3 is required to verify the parts. Install the Xcode Command Line Tools, then retry."
    read -r -p "Press Return to close." _
    exit 1
fi
[ -f join_release.py ] || { echo "Missing join_release.py next to this script."; exit 1; }

OUTPUT="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["output"])' "$MANIFEST")"
case "$OUTPUT" in
    ""|.*|*/*|*\\*) echo "The parts manifest has an unsafe output name: $OUTPUT" >&2; exit 1 ;;
esac
if [ -e "$OUTPUT" ]; then
    read -r -p "$OUTPUT already exists. Replace it? [y/N] " REPLACE
    case "$REPLACE" in
        y|Y|yes|YES) ;;
        *) echo "Keeping the existing $OUTPUT."; exit 1 ;;
    esac
fi
"$PYTHON" join_release.py "$MANIFEST" --download --force --output "$OUTPUT"
hdiutil verify -quiet "$OUTPUT"
open "$OUTPUT"
