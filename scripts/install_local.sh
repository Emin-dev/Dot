#!/bin/bash
# Build, assemble and install the complete local Dot app on this Mac.
#
# The development build (build.sh) intentionally ships without the neural payload,
# so this script does what a maintainer otherwise does by hand: build with the
# speech recognizer, clone the owner's existing payload, record honest provenance,
# sign with the stable identity (so macOS keeps the microphone/screen grants),
# swap the app in, relaunch and verify.
#
# It never downloads anything and never touches the payload's contents.
#
# Usage:
#   bash scripts/install_local.sh
# Environment:
#   DOT_WHISPER_FRAMEWORK  optional; defaults to the framework inside the app being
#                          replaced, so an existing installation is the source.
#   DOT_INSTALL_PATH       optional; defaults to ~/Applications/Dot.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${DOT_INSTALL_PATH:-$HOME/Applications/Dot.app}"
BACKUP="$APP.backup-latest"
STAGE="/private/tmp/dot-install-$$"
SIGN_IDENTITY="Apple Development: Emin Ismayilov (7M2G5ULAUF)"

fail() { echo "install_local: $*" >&2; exit 1; }

[ -d "$APP" ] || fail "no app at $APP to upgrade (and therefore no payload to clone)"
[ -d "$APP/Contents/Resources/Offline" ] || fail "$APP has no Offline payload"
[ -d "$APP/Contents/Resources/OfflineModels" ] || fail "$APP has no OfflineModels payload"

# The recognizer is a compile-time branch: a build without it can never listen.
# Default to the framework already inside the app we are replacing.
FRAMEWORK="${DOT_WHISPER_FRAMEWORK:-$APP/Contents/Frameworks/whisper.framework}"
[ -f "$FRAMEWORK/Modules/module.modulemap" ] || fail "no usable whisper.framework at $FRAMEWORK"

command -v cargo >/dev/null || fail "cargo is required (the Rust runtime is built here)"

echo "==> quitting any running Dot"
osascript -e 'tell application "Dot" to quit' 2>/dev/null || true
sleep 3
if pgrep -x Dot >/dev/null; then pkill -x Dot; sleep 2; fi

echo "==> building (Rust binaries + app, recognizer embedded)"
# Freshness guard: a failed or silently no-op build must never install stale
# binaries and stamp them with today's provenance.
if [ -f build/Dot.app/Contents/MacOS/Dot ]; then
  PRE_EXEC_HASH="$(shasum -a 256 build/Dot.app/Contents/MacOS/Dot | awk '{print $1}')"
else
  PRE_EXEC_HASH=""
fi
DOT_WHISPER_FRAMEWORK="$FRAMEWORK" bash build.sh >/tmp/dot-install-build.log 2>&1 || fail "build.sh failed (see /tmp/dot-install-build.log)"
[ -x build/Dot.app/Contents/MacOS/Dot ] || fail "build produced no executable (see /tmp/dot-install-build.log)"
[ "$(shasum -a 256 build/Dot.app/Contents/MacOS/Dot | awk '{print $1}')" != "$PRE_EXEC_HASH" ] \
  || fail "build.sh left the app binary unchanged; refusing to install stale binaries (see /tmp/dot-install-build.log)"

echo "==> assembling the complete bundle in $STAGE"
rm -rf "$STAGE"; mkdir -p "$STAGE"
# Clone (APFS copy-on-write) so the 20 GB payload is not duplicated on disk.
cp -c -R build/Dot.app "$STAGE/Dot.app" 2>/dev/null || cp -R build/Dot.app "$STAGE/Dot.app"
for item in Offline OfflineModels; do
  rm -rf "$STAGE/Dot.app/Contents/Resources/$item"
  cp -c -R "$APP/Contents/Resources/$item" "$STAGE/Dot.app/Contents/Resources/$item" 2>/dev/null \
    || cp -R "$APP/Contents/Resources/$item" "$STAGE/Dot.app/Contents/Resources/$item"
done

# One minimum-OS policy (macOS 26.4), the same override build_complete.sh applies;
# the installed app must carry it even if build.sh's copy ever drifted.
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 26.4' "$STAGE/Dot.app/Contents/Info.plist"

echo "==> provenance"
/usr/bin/python3 - "$STAGE/Dot.app/Contents/Resources/build-provenance.json" <<'PY'
import json, pathlib, subprocess, sys
path = pathlib.Path(sys.argv[1])
record = json.loads(path.read_text())
record.update({
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()),
    # This development install can read its own Dot checkout. A public build has
    # no source_root and says so instead of searching a path from another machine.
    'source_root': str(pathlib.Path.cwd()),
    'signing': 'apple-development', 'notarized': False,
    'runtime_bundled': True, 'models_bundled': True,
})
path.write_text(json.dumps(record, indent=2) + '\n')
print('   commit', record['commit'][:7], '| dirty', record['source_dirty'],
      '| runtime_bundled', record['runtime_bundled'], '| models_bundled', record['models_bundled'])
PY

echo "==> signing with $SIGN_IDENTITY"
# A cloud-synced checkout gets Finder/FileProvider attributes that codesign
# rejects ("resource fork, Finder information, or similar detritus not allowed").
xattr -cr "$STAGE/Dot.app"
# No --deep: re-signing nested code corrupts the seal and blocks notarytool.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$STAGE/Dot.app"
codesign --verify --strict "$STAGE/Dot.app" || fail "staged signature did not verify"

echo "==> swapping in (previous app kept at $BACKUP)"
rm -rf "$BACKUP"
mv "$APP" "$BACKUP"
cp -c -R "$STAGE/Dot.app" "$APP" 2>/dev/null || cp -R "$STAGE/Dot.app" "$APP"
codesign --verify --strict "$APP" || fail "installed signature did not verify"

echo "==> launching and verifying"
open -a "$APP"
sleep 12
PID="$(pgrep -x Dot | tr '\n' ' ')"
[ -n "$PID" ] || fail "the installed app did not stay running"

INSTALLED="$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['commit'][:7])" \
  "$APP/Contents/Resources/build-provenance.json")"
HEAD="$(git rev-parse --short HEAD)"
echo "installed $APP"
echo "  provenance $INSTALLED | HEAD $HEAD | pid $PID"
echo "  binaries: $(ls "$APP/Contents/MacOS" | tr '\n' ' ')"
[ "$INSTALLED" = "$HEAD" ] || echo "  note: working tree is ahead of the installed provenance"
rm -rf "$STAGE"
echo "PASS: complete app installed, signed and running"
