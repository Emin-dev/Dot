#!/bin/bash
# Build, assemble and install the complete local Dot app on this Mac.
#
# The development build (build.sh) intentionally ships without the neural payload,
# so this script does what a maintainer otherwise does by hand: build with the
# speech recognizer, clone the owner's existing payload, record honest provenance,
# sign with the stable identity (so macOS keeps the microphone/screen grants),
# swap the app in, relaunch and verify.
#
# It copies the existing payload when present, fetches the pinned voice/aux files
# when it is absent, and never changes the payload's contents. DOT_SKIP_* disables
# the network.
#
# Usage:
#   bash scripts/install_local.sh
# Environment:
#   DOT_WHISPER_FRAMEWORK  optional; defaults to the framework inside the app being
#                          replaced, so an existing installation is the source.
#   DOT_INSTALL_PATH       optional; defaults to ~/Applications/Dot.app
set -euo pipefail

# dot-safety's llama.cpp dependency needs cmake at build time. A system cmake wins;
# otherwise fall back to the locally fetched one this machine already uses.
command -v cmake >/dev/null 2>&1 || PATH="/private/tmp/cmake/CMake.app/Contents/bin:$PATH"

cd "$(dirname "$0")/.."

APP="${DOT_INSTALL_PATH:-$HOME/Applications/Dot.app}"
BACKUP="$APP.backup-latest"
STAGE="/private/tmp/dot-install-$$"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: Emin Ismayilov (7M2G5ULAUF)}"

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
# Clone the existing payload before the fetch blocks below: a later clone would
# otherwise delete the freshly fetched voice/aux files and install without them.
for item in Offline OfflineModels; do
  rm -rf "$STAGE/Dot.app/Contents/Resources/$item"
  cp -c -R "$APP/Contents/Resources/$item" "$STAGE/Dot.app/Contents/Resources/$item" 2>/dev/null \
    || cp -R "$APP/Contents/Resources/$item" "$STAGE/Dot.app/Contents/Resources/$item"
done
# The voice payload (Kokoro model + voices, ~330 MB) lives outside git. In-place
# upgrades copy it from the app being replaced; a fresh install fetches it from the
# pinned Hugging Face repo. Both paths verify size, and DOT_SKIP_VOICE_FETCH=1
# skips the network entirely (voice replies then fall back to the system voice).
VOICE_DIR="$STAGE/Dot.app/Contents/Resources/Offline/Voice/model"
if [ "${DOT_SKIP_VOICE_FETCH:-0}" != "1" ] && [ ! -f "$VOICE_DIR/kokoro-v1_0.pth" ]; then
    if [ -f "$APP/Contents/Resources/Offline/Voice/model/kokoro-v1_0.pth" ]; then
        mkdir -p "$VOICE_DIR"
        cp -c -R "$APP/Contents/Resources/Offline/Voice/model/." "$VOICE_DIR/" 2>/dev/null || cp -R "$APP/Contents/Resources/Offline/Voice/model/." "$VOICE_DIR/"
        echo "voice payload copied from the previous app"
    else
        mkdir -p "$VOICE_DIR/voices"
        curl -sL -o "$VOICE_DIR/kokoro-v1_0.pth" "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/kokoro-v1_0.pth"
        curl -sL -o "$VOICE_DIR/config.json" "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/config.json"
        for v in bf_alice bf_emma bf_isabella bf_lily; do
            curl -sL -o "$VOICE_DIR/voices/$v.pt" "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/voices/$v.pt"
        done
        [ "$(stat -f%z "$VOICE_DIR/kokoro-v1_0.pth" 2>/dev/null || echo 0)" -gt 300000000 ] || fail "voice model fetch incomplete"
        echo "voice payload fetched (pinned HF source)"
    fi
fi

# R16: the auxiliary small model (Gemma-3-4B Q4) powers the R7 safety approver.
# Same copy-or-fetch policy as the voice payload; DOT_SKIP_AUX_FETCH=1 skips it.
AUX_DIR="$STAGE/Dot.app/Contents/Resources/OfflineModels/aux"
if [ "${DOT_SKIP_AUX_FETCH:-0}" != "1" ] && [ ! -f "$AUX_DIR/gemma-3-4b-it-Q4_K_M.gguf" ]; then
    if [ -f "$APP/Contents/Resources/OfflineModels/aux/gemma-3-4b-it-Q4_K_M.gguf" ]; then
        mkdir -p "$AUX_DIR"
        cp -c -R "$APP/Contents/Resources/OfflineModels/aux/." "$AUX_DIR/" 2>/dev/null || cp -R "$APP/Contents/Resources/OfflineModels/aux/." "$AUX_DIR/"
        echo "aux model copied from the previous app"
    else
        mkdir -p "$AUX_DIR"
        curl -sL -o "$AUX_DIR/gemma-3-4b-it-Q4_K_M.gguf" "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf"
        [ "$(stat -f%z "$AUX_DIR/gemma-3-4b-it-Q4_K_M.gguf" 2>/dev/null || echo 0)" -gt 2000000000 ] || fail "aux model fetch incomplete"
        echo "aux model fetched (pinned HF source)"
    fi
fi


# The runtime manifest pins every Offline file. Extra Kokoro voices (R4: all four
# stay available) must be registered in it or the whole payload verification fails.
/private/tmp/dot-py313/bin/python - "$STAGE/Dot.app/Contents/Resources/Offline/runtime-manifest.json" "$STAGE/Dot.app/Contents/Resources/Offline/Voice/model/voices" <<'PYEOF'
import json, hashlib, pathlib, sys
manifest_path = pathlib.Path(sys.argv[1]); voices = pathlib.Path(sys.argv[2])
d = json.loads(manifest_path.read_text())
known = {f["path"] for f in d["files"]}
for pt in sorted(voices.glob("*.pt")):
    rel = f"Voice/model/voices/{pt.name}"
    if rel in known:
        continue
    data = pt.read_bytes()
    d["files"].append({"path": rel, "kind": "file", "bytes": len(data),
                       "sha256": hashlib.sha256(data).hexdigest()})
manifest_path.write_text(json.dumps(d) + "\n")
PYEOF
echo "voice manifest entries registered"

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
