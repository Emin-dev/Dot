#!/bin/bash
# Developer packaging entry point. Uses only already-verified local build inputs.
# No downloads, package installation, app launch, microphone or model inference.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DOT_RUNTIME_PAYLOAD:?Set DOT_RUNTIME_PAYLOAD to the completed, audited local runtime payload}"
: "${DOT_WHISPER_FRAMEWORK:?Set DOT_WHISPER_FRAMEWORK to the verified macOS whisper.framework}"
python3 -B scripts/audit_runtime_payload.py "$DOT_RUNTIME_PAYLOAD"
test -f "$DOT_WHISPER_FRAMEWORK/Modules/module.modulemap"
test -f "$DOT_WHISPER_FRAMEWORK/Headers/whisper.h"
FRAMEWORK_PARENT=$(dirname "$DOT_WHISPER_FRAMEWORK")
APP=build-complete/Dot.app
if [[ -e "$APP" ]]; then
  echo "Refusing to replace an existing complete build; preserve it and choose a fresh build workspace."; exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Voice" "$APP/Contents/Resources/Runtime" "$APP/Contents/Frameworks"
swiftc -O -warnings-as-errors -D DOT_COMPLETE_BUNDLE -target arm64-apple-macosx26.4 \
  -F "$FRAMEWORK_PARENT" -framework whisper -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/Dot" src/*.swift \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework CryptoKit
# This is an actual native-library reference check, not a canImport fallback build.
nm -u "$APP/Contents/MacOS/Dot" | grep _whisper_full >/dev/null
/usr/bin/ditto "$DOT_WHISPER_FRAMEWORK" "$APP/Contents/Frameworks/whisper.framework"
/usr/bin/ditto "$DOT_RUNTIME_PAYLOAD" "$APP/Contents/Resources/Offline"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 26.4' "$APP/Contents/Info.plist"
cp Resources/Voice/bionic_helper.py Resources/Voice/BIONIC-LICENSE.txt "$APP/Contents/Resources/Voice/"
cp Resources/Runtime/dot_runtime.py Resources/Runtime/splash.sb "$APP/Contents/Resources/Runtime/"
cp Resources/model-downloads.json "$APP/Contents/Resources/"
MODEL_DOWNLOAD=true
if [[ -n "${DOT_MODEL_PAYLOAD:-}" ]]; then
  python3 -B scripts/copy_offline_models.py --source "$DOT_MODEL_PAYLOAD" \
    --destination "$APP/Contents/Resources/OfflineModels" --manifest Resources/model-downloads.json
  MODEL_DOWNLOAD=false
fi
printf '{"commit":"%s","signing":"ad-hoc","notarized":false,"runtime_bundled":true,"llm_weights_download_on_first_launch":%s}\n' "$(git rev-parse HEAD)" "$MODEL_DOWNLOAD" > "$APP/Contents/Resources/build-provenance.json"
ICONSET=build-complete/Icon.iconset; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z "$d" "$d" icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Icon.icns"
# Runtime native code must already be finalized/signed before its immutable manifest was made.
codesign --force --sign - "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
python3 -B scripts/audit_runtime_payload.py "$APP/Contents/Resources/Offline"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/dot-complete.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/Dot.app"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Dot -srcfolder "$STAGE" -ov -format UDZO -o build-complete/Dot.dmg
shasum -a 256 build-complete/Dot.dmg
printf 'Complete-runtime test installer built. Model download on first launch: %s. Ad-hoc signed; not notarized.\n' "$MODEL_DOWNLOAD"
