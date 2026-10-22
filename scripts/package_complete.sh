#!/bin/bash
# Package only the exact app for which real native acceptance evidence exists.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DOT_OFFLINE_ACCEPTANCE:?Set to the real native offline acceptance JSON and evidence directory}"
APP=build-complete/Dot.app
codesign --verify --deep --strict "$APP"
python3 -B scripts/audit_runtime_payload.py "$APP/Contents/Resources/Offline"
python3 -B scripts/offline_acceptance.py "$APP" --receipt "$DOT_OFFLINE_ACCEPTANCE"
[[ ! -e build-complete/Dot.dmg ]] || { echo 'Preserve the existing installer before packaging.'; exit 1; }
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/dot-complete.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/Dot.app"
# Verify the relocated copy, including all model bytes and internal link destinations.
python3 -B scripts/offline_acceptance.py "$STAGE/Dot.app" --receipt "$DOT_OFFLINE_ACCEPTANCE"
python3 -B scripts/create_dmg.py "$STAGE" build-complete/Dot.dmg
shasum -a 256 build-complete/Dot.dmg
printf 'Offline-accepted test installer packaged. Ad-hoc signed; not notarized.\n'
