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
: "${DOT_WHISPER_ARCHIVE:?Set DOT_WHISPER_ARCHIVE to the repository-pinned whisper-v1.7.6-xcframework.zip}"
python3 -B scripts/audit_runtime_payload.py "$DOT_RUNTIME_PAYLOAD"
INTENTS_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/dot-intents-complete.XXXXXX")
WHISPER_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/dot-whisper-complete.XXXXXX")
trap 'rm -rf "$INTENTS_BUILD" "$WHISPER_BUILD"' EXIT
# Authenticate the archive and derive this framework from those exact bytes.
# Never link or copy an independently supplied framework directory.
git ls-files --error-unmatch -- packaging/voice-source-manifest.json scripts/verify_whisper_input.py >/dev/null
python3 -B scripts/verify_whisper_input.py --archive "$DOT_WHISPER_ARCHIVE" \
  --output "$WHISPER_BUILD/whisper-input" > "$WHISPER_BUILD/whisper-input.json"
VERIFIED_WHISPER_FRAMEWORK="$WHISPER_BUILD/whisper-input/whisper.framework"
FRAMEWORK_PARENT="$WHISPER_BUILD/whisper-input"
SOURCES=(src/*.swift)
python3 -B scripts/package_app_intents.py prepare --work-dir "$INTENTS_BUILD" "${SOURCES[@]}"
APP=build-complete/Dot.app
if [[ -e "$APP" ]]; then
  echo "Refusing to replace an existing complete build; preserve it and choose a fresh build workspace."; exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Voice" "$APP/Contents/Resources/Runtime" "$APP/Contents/Frameworks"
xcrun swiftc -O -warnings-as-errors -module-name Dot -D DOT_COMPLETE_BUNDLE -target arm64-apple-macosx26.4 \
  -module-cache-path "$INTENTS_BUILD/module-cache" \
  -emit-const-values -Xfrontend -const-gather-protocols-file -Xfrontend "$INTENTS_BUILD/protocols.json" \
  -output-file-map "$INTENTS_BUILD/output-map.json" \
  -F "$FRAMEWORK_PARENT" -framework whisper -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/Dot" "${SOURCES[@]}" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework Vision -framework CryptoKit
# This is an actual native-library reference check, not a canImport fallback build.
nm -u "$APP/Contents/MacOS/Dot" | grep _whisper_full >/dev/null
/usr/bin/ditto "$VERIFIED_WHISPER_FRAMEWORK" "$APP/Contents/Frameworks/whisper.framework"
/usr/bin/ditto "$DOT_RUNTIME_PAYLOAD" "$APP/Contents/Resources/Offline"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 26.4' "$APP/Contents/Info.plist"
cp Resources/Voice/bionic_helper.py Resources/Voice/BIONIC-LICENSE.txt Resources/Voice/voice.sb "$APP/Contents/Resources/Voice/"
cp Resources/Runtime/dot_runtime.py Resources/Runtime/dot_process.py Resources/Runtime/dot_tls.py Resources/Runtime/splash.sb Resources/Runtime/splash-managed-listener-patch.json "$APP/Contents/Resources/Runtime/"
cp Resources/bundled-models.json "$APP/Contents/Resources/"
cp -R Resources/Research Resources/Search "$APP/Contents/Resources/"
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
SIGN_IDENTITY=$(security find-identity -p codesigning -v | grep -o 'Apple Development: [^"]*' | head -n 1 || true)
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
fi
if [[ -f target/release/dot-search ]]; then
  cp target/release/dot-search "$APP/Contents/MacOS/dot-search"
  codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/dot-search"
fi
if [[ -f target/release/dot-voice ]]; then
  cp target/release/dot-voice "$APP/Contents/MacOS/dot-voice"
  codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/dot-voice"
fi
# Runtime native code must already be finalized/signed before its immutable manifest was made.
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
assert_source_snapshot
python3 -B - "$APP" "$SOURCE_COMMIT" "$WHISPER_BUILD/whisper-input.json" <<'PYCODE'
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
# Archive/closure hashes describe authenticated pre-signing input. The separate
# embedded binary hash above records the final ad-hoc-signed binary.
sys.path.insert(0, str(pathlib.Path('scripts').resolve()))
from verify_whisper_input import read_receipt
whisper = read_receipt(sys.argv[3])
record.update({'whisper_input_archive_sha256': whisper['archive_sha256'],
               'whisper_input_archive_bytes': whisper['archive_bytes'],
               'whisper_input_framework_closure_sha256': whisper['framework_closure_sha256'],
               'whisper_input_library_identifier': whisper['library_identifier'],
               'whisper_source_manifest_sha256': whisper['source_manifest_sha256']})
(resources / 'build-provenance.json').write_text(json.dumps(record, indent=2) + '\n')
PYCODE
codesign --force --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
python3 -B scripts/audit_runtime_payload.py "$APP/Contents/Resources/Offline"
printf 'Bundled app staged for native offline acceptance: %s. No installer released.\n' "$APP"
printf 'After real relocation/conversation/cancellation tests, run scripts/package_complete.sh with the acceptance record.\n'
