#!/bin/bash
# Build only. Does not launch Dot, access a microphone or start/download engines.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Dot.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -warnings-as-errors -target "$(uname -m)-apple-macosx15.0" -o "$APP/Contents/MacOS/Dot" src/*.swift \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework CryptoKit
mkdir -p "$APP/Contents/Resources/Voice" "$APP/Contents/Resources/Runtime"
cp Resources/Runtime/dot_runtime.py Resources/Runtime/dot_process.py Resources/Runtime/splash.sb "$APP/Contents/Resources/Runtime/"
cp Resources/bundled-models.json "$APP/Contents/Resources/"
cp Resources/Voice/bionic_helper.py Resources/Voice/BIONIC-LICENSE.txt "$APP/Contents/Resources/Voice/"
printf '{"commit":"%s","signing":"ad-hoc","notarized":false,"voice_protocol":1,"runtime_bundled":false,"models_bundled":false,"llm_weights_download_on_first_launch":false}\n' "$(git rev-parse HEAD)" > "$APP/Contents/Resources/build-provenance.json"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ICONSET=build/Icon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Icon.icns"
codesign --force --sign - "$APP"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/dot-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Dot -srcfolder "$STAGE" -ov -format UDZO -o build/Dot.dmg
printf 'Built %s/build/Dot.dmg (development-only, no neural runtimes; ad-hoc signed, not notarized)\n' "$PWD"
