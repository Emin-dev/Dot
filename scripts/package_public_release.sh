#!/bin/bash
# Build the downloadable public app: the complete runtime without the 19.9 GB model.
#
# The app verifies its signed manifest and downloads the exact model files from
# Hugging Face into ~/Library/Application Support/Dot/Models on first launch. The
# resulting DMG/ZIP must stay under GitHub's 2 GB per-asset limit.
#
# Usage:
#   bash scripts/package_public_release.sh
# Environment:
#   DOT_APP           source complete app (default ~/Applications/Dot.app)
#   DOT_RELEASE_DIR   output directory (default build-public)
#   SIGN_IDENTITY     signing identity (default matches scripts/install_local.sh)
#
# This does not notate or publish. Upload the printed zip to a GitHub release as
# Dot.zip so the README download button and one-line installer resolve.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${DOT_APP:-$HOME/Applications/Dot.app}"
OUT="${DOT_RELEASE_DIR:-build-public}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: Emin Ismayilov (7M2G5ULAUF)}"
STAGE="/private/tmp/dot-public-$$"
ZIP="$OUT/Dot.zip"

fail() { echo "package_public_release: $*" >&2; exit 1; }
[ -d "$APP" ] || fail "no app at $APP"
[ -d "$APP/Contents/Resources/Offline" ] || fail "$APP has no Offline runtime"
[ -d "$APP/Contents/Resources/OfflineModels" ] || fail "$APP has no model payload (nothing to strip)"
[ -f "$APP/Contents/Resources/build-provenance.json" ] || fail "no provenance in $APP"

echo "==> staging the runtime-only app"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -c -R "$APP" "$STAGE/Dot.app" 2>/dev/null || cp -R "$APP" "$STAGE/Dot.app"
rm -rf "$STAGE/Dot.app/Contents/Resources/OfflineModels"
du -sh "$STAGE/Dot.app"

echo "==> marking the public provenance"
/usr/bin/python3 - "$STAGE/Dot.app/Contents/Resources/build-provenance.json" <<'PY'
import json, pathlib, subprocess, sys
path = pathlib.Path(sys.argv[1])
record = json.loads(path.read_text())
record.update({
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()),
    'signing': 'apple-development',
    'notarized': False,
    'runtime_bundled': True,
    'models_bundled': False,
    'models_downloaded': True,
})
record.pop('source_root', None)
path.write_text(json.dumps(record, indent=2) + '\n')
print('   commit', record['commit'][:7], '| models_bundled', record['models_bundled'])
PY

echo "==> signing after removing the sealed model resources"
xattr -cr "$STAGE/Dot.app"
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$STAGE/Dot.app"
codesign --verify --strict "$STAGE/Dot.app" || fail "staged signature did not verify"

echo "==> creating $ZIP"
mkdir -p "$OUT"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/Dot.app" "$ZIP"
SIZE=$(stat -f%z "$ZIP")
[ "$SIZE" -lt 2000000000 ] || fail "zip is $SIZE bytes; GitHub rejects assets at 2 GB"
shasum -a 256 "$ZIP" > "$ZIP.sha256"

DMG="$OUT/Dot.dmg"
echo "==> creating $DMG"
DMGROOT="$STAGE/dmg"
rm -rf "$DMGROOT"; mkdir -p "$DMGROOT"
cp -c -R "$STAGE/Dot.app" "$DMGROOT/Dot.app" 2>/dev/null || cp -R "$STAGE/Dot.app" "$DMGROOT/Dot.app"
ln -s /Applications "$DMGROOT/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Dot" -srcfolder "$DMGROOT" -ov -format UDZO "$DMG"
hdiutil verify -quiet "$DMG" || fail "DMG failed verification"
DSIZE=$(stat -f%z "$DMG")
[ "$DSIZE" -lt 2000000000 ] || fail "DMG is $DSIZE bytes; GitHub rejects assets at 2 GB"
shasum -a 256 "$DMG" > "$DMG.sha256"
ls -lh "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256"
echo
echo "PASS: runtime-only public app packaged (models download on first launch)"
echo "Upload $DMG as Dot.dmg (recommended) and $ZIP as Dot.zip to"
echo "https://github.com/Emin-dev/Dot/releases/new, or run scripts/publish_public_release.sh."
echo "Until those assets exist the README buttons have nothing to serve."
rm -rf "$STAGE"
