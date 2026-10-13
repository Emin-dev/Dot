#!/bin/bash
# Developer packaging entry point. Uses only already-verified local build inputs.
# No downloads, package installation, app launch, microphone or model inference.
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE_COMMIT=$(git rev-parse HEAD)
assert_source_snapshot() {
  [[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || { echo 'Source revision changed during assembly.'; exit 1; }
  git diff --quiet && git diff --cached --quiet || { echo 'Commit or preserve source changes before a provenance-labelled build.'; exit 1; }
  [[ -z "$(git ls-files --others -- src Resources scripts)" ]] || { echo 'Untracked or ignored build inputs must be reviewed before packaging.'; exit 1; }
}
assert_source_snapshot
: "${DOT_RUNTIME_PAYLOAD:?Set DOT_RUNTIME_PAYLOAD to the completed, audited local runtime payload}"
: "${DOT_MODEL_PAYLOAD:?Set DOT_MODEL_PAYLOAD to the verified complete target, draft and vision model payload}"
: "${DOT_WHISPER_FRAMEWORK:?Set DOT_WHISPER_FRAMEWORK to the verified macOS whisper.framework}"
python3 -B scripts/audit_runtime_payload.py "$DOT_RUNTIME_PAYLOAD"
test -f "$DOT_WHISPER_FRAMEWORK/Modules/module.modulemap"
test -f "$DOT_WHISPER_FRAMEWORK/Headers/whisper.h"
FRAMEWORK_PARENT=$(dirname "$DOT_WHISPER_FRAMEWORK")
INTENTS_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/dot-intents-complete.XXXXXX")
trap 'rm -rf "$INTENTS_BUILD"' EXIT
SOURCES=(src/*.swift)
python3 -B scripts/package_app_intents.py prepare --work-dir "$INTENTS_BUILD" "${SOURCES[@]}"
APP=build-complete/Dot.app
if [[ -e "$APP" ]]; then
  echo "Refusing to replace an existing complete build; preserve it and choose a fresh build workspace."; exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Voice" "$APP/Contents/Resources/Runtime" "$APP/Contents/Frameworks"
xcrun swiftc -O -warnings-as-errors -module-name Dot -D DOT_COMPLETE_BUNDLE -target arm64-apple-macosx26.4 \
  -module-cache-path "$INTENTS_BUILD/module-cache" \
  -emit-const-values -const-gather-protocols-list "$INTENTS_BUILD/protocols.json" \
  -output-file-map "$INTENTS_BUILD/output-map.json" \
  -F "$FRAMEWORK_PARENT" -framework whisper -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/Dot" "${SOURCES[@]}" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework Vision -framework CryptoKit
# This is an actual native-library reference check, not a canImport fallback build.
nm -u "$APP/Contents/MacOS/Dot" | grep _whisper_full >/dev/null
/usr/bin/ditto "$DOT_WHISPER_FRAMEWORK" "$APP/Contents/Frameworks/whisper.framework"
/usr/bin/ditto "$DOT_RUNTIME_PAYLOAD" "$APP/Contents/Resources/Offline"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 26.4' "$APP/Contents/Info.plist"
cp Resources/Voice/bionic_helper.py Resources/Voice/BIONIC-LICENSE.txt Resources/Voice/voice.sb "$APP/Contents/Resources/Voice/"
cp Resources/Runtime/dot_runtime.py Resources/Runtime/dot_process.py Resources/Runtime/dot_tls.py Resources/Runtime/splash.sb Resources/Runtime/splash-managed-listener-patch.json "$APP/Contents/Resources/Runtime/"
cp Resources/bundled-models.json "$APP/Contents/Resources/"
python3 -B scripts/copy_offline_models.py --source "$DOT_MODEL_PAYLOAD" \
  --destination "$APP/Contents/Resources/OfflineModels" --manifest Resources/bundled-models.json
ICONSET=build-complete/Icon.iconset; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z "$d" "$d" icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Icon.icns"
python3 -B scripts/package_app_intents.py extract --work-dir "$INTENTS_BUILD" --app "$APP" \
  --target arm64-apple-macosx26.4 --deployment-target 26.4
# Runtime native code must already be finalized/signed before its immutable manifest was made.
codesign --force --sign - "$APP/Contents/Frameworks/whisper.framework"
assert_source_snapshot
python3 -B - "$APP" "$SOURCE_COMMIT" <<'PYCODE'
import hashlib, json, pathlib, sys
app = pathlib.Path(sys.argv[1]); resources = app / 'Contents/Resources'
manifest = resources / 'Offline/runtime-manifest.json'
framework = app / 'Contents/Frameworks/whisper.framework/whisper'
digest = hashlib.sha256()
with framework.open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
record = {'commit': sys.argv[2], 'source_dirty': False,
          'signing': 'ad-hoc', 'notarized': False, 'runtime_bundled': True,
          'llm_weights_download_on_first_launch': False, 'models_bundled': True,
          'runtime_manifest_sha256': hashlib.sha256(manifest.read_bytes()).hexdigest(),
          'model_plan_sha256': hashlib.sha256((resources / 'bundled-models.json').read_bytes()).hexdigest(),
          'embedded_whisper_binary_sha256': digest.hexdigest()}
(resources / 'build-provenance.json').write_text(json.dumps(record, indent=2) + '\n')
PYCODE
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
python3 -B scripts/audit_runtime_payload.py "$APP/Contents/Resources/Offline"
printf 'Bundled app staged for native offline acceptance: %s. No installer released.\n' "$APP"
printf 'After real relocation/conversation/cancellation tests, run scripts/package_complete.sh with the acceptance record.\n'
