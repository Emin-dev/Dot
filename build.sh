#!/bin/bash
# Build only. Does not launch Dot, access a microphone or start/download engines.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Dot.app
SOURCE_COMMIT=$(git rev-parse HEAD)
SOURCE_DIRTY=false
if [[ -n "$(git status --porcelain --untracked-files=all -- src Resources scripts Tests Dot.xcodeproj Package.swift build.sh)" || \
      -n "$(git ls-files --others -- src Resources scripts Tests Dot.xcodeproj Package.swift build.sh)" ]]; then
  SOURCE_DIRTY=true
fi
INTENTS_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/dot-intents.XXXXXX")
STAGE=""
trap 'rm -rf "$INTENTS_BUILD"; if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi' EXIT
TARGET="$(uname -m)-apple-macosx15.0"
SOURCES=(src/*.swift)
python3 -B scripts/package_app_intents.py prepare --work-dir "$INTENTS_BUILD" "${SOURCES[@]}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -warnings-as-errors -module-name Dot -target "$TARGET" \
  -module-cache-path "$INTENTS_BUILD/module-cache" \
  -emit-const-values -Xfrontend -const-gather-protocols-file -Xfrontend "$INTENTS_BUILD/protocols.json" \
  -output-file-map "$INTENTS_BUILD/output-map.json" -o "$APP/Contents/MacOS/Dot" "${SOURCES[@]}" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework Vision -framework CryptoKit
mkdir -p "$APP/Contents/Resources/Voice" "$APP/Contents/Resources/Runtime"
cp Resources/Runtime/dot_runtime.py Resources/Runtime/dot_process.py Resources/Runtime/dot_tls.py Resources/Runtime/splash.sb Resources/Runtime/splash-managed-listener-patch.json "$APP/Contents/Resources/Runtime/"
cp Resources/bundled-models.json "$APP/Contents/Resources/"
cp Resources/Voice/bionic_helper.py Resources/Voice/BIONIC-LICENSE.txt Resources/Voice/voice.sb "$APP/Contents/Resources/Voice/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ICONSET=build/Icon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Icon.icns"
python3 -B scripts/package_app_intents.py extract --work-dir "$INTENTS_BUILD" --app "$APP" \
  --target "$TARGET" --deployment-target 15.0
python3 -B - "$APP" "$SOURCE_COMMIT" "$SOURCE_DIRTY" <<'PYCODE'
import json, pathlib, subprocess, sys
paths = ['src', 'Resources', 'scripts', 'Tests', 'Dot.xcodeproj', 'Package.swift', 'build.sh']
changed = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all', '--', *paths], text=True)
untracked = subprocess.check_output(['git', 'ls-files', '--others', '--', *paths], text=True)
current = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
record = {'commit': sys.argv[2], 'source_dirty': sys.argv[3] == 'true' or bool(changed.strip() or untracked.strip()) or current != sys.argv[2],
          'signing': 'ad-hoc', 'notarized': False, 'voice_protocol': 1, 'runtime_bundled': False,
          'models_bundled': False, 'llm_weights_download_on_first_launch': False}
(pathlib.Path(sys.argv[1]) / 'Contents/Resources/build-provenance.json').write_text(json.dumps(record, indent=2) + '\n')
PYCODE
codesign --force --sign - "$APP"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/dot-stage.XXXXXX")
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
python3 -B scripts/create_dmg.py "$STAGE" build/Dot.dmg
printf 'Built %s/build/Dot.dmg (development-only, no neural runtimes; ad-hoc signed, not notarized)\n' "$PWD"
