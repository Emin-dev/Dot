#!/bin/bash
# Build only. Does not launch Dot, access a microphone or start/download engines.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Dot.app
SOURCE_COMMIT=$(git rev-parse HEAD)
SOURCE_DIRTY=false
if [[ -n "$(git status --porcelain --untracked-files=all -- src Resources scripts Tests Dot.xcodeproj Package.swift build.sh icon.png crates Cargo.toml Cargo.lock packaging)" || \
      -n "$(git ls-files --others -- src Resources scripts Tests Dot.xcodeproj Package.swift build.sh icon.png crates Cargo.toml Cargo.lock packaging)" ]]; then
  SOURCE_DIRTY=true
fi
INTENTS_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/dot-intents.XXXXXX")
STAGE=""
trap 'rm -rf "$INTENTS_BUILD"; if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi' EXIT
TARGET="$(uname -m)-apple-macosx26.4"
SOURCES=(src/*.swift)
# The runtime is Rust-only. Build the binaries first so the bundle always carries
# them; an absent binary would otherwise silently change runtime behaviour.
command -v cargo >/dev/null || { echo 'cargo is required to build the Dot runtime' >&2; exit 1; }
cargo build --release --manifest-path Cargo.toml --bin dot-voice --bin dot-search --bin dot-fetch --bin dot-safety
python3 -B scripts/package_app_intents.py prepare --work-dir "$INTENTS_BUILD" "${SOURCES[@]}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The speech recognizer is a compile-time branch (`#if canImport(whisper)`), so a
# build without the framework produces an app that can never listen. Point
# DOT_WHISPER_FRAMEWORK at a verified whisper.framework to build a talking app; the
# framework is embedded and linked with the matching rpath.
WHISPER_FLAGS=()
if [[ -n "${DOT_WHISPER_FRAMEWORK:-}" ]]; then
  test -f "$DOT_WHISPER_FRAMEWORK/Modules/module.modulemap" || { echo "DOT_WHISPER_FRAMEWORK must point at a whisper.framework containing Modules/module.modulemap" >&2; exit 1; }
  WHISPER_FLAGS=(-D DOT_COMPLETE_BUNDLE -F "$(dirname "$DOT_WHISPER_FRAMEWORK")" -framework whisper -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
  mkdir -p "$APP/Contents/Frameworks"
  rm -rf "$APP/Contents/Frameworks/whisper.framework"
  cp -c -R "$DOT_WHISPER_FRAMEWORK" "$APP/Contents/Frameworks/" 2>/dev/null || cp -R "$DOT_WHISPER_FRAMEWORK" "$APP/Contents/Frameworks/"
  echo "Embedding speech recognizer: $(basename "$DOT_WHISPER_FRAMEWORK")"
fi
xcrun swiftc -O -warnings-as-errors -module-name Dot -target "$TARGET" \
  -module-cache-path "$INTENTS_BUILD/module-cache" \
  -emit-const-values -Xfrontend -const-gather-protocols-file -Xfrontend "$INTENTS_BUILD/protocols.json" \
  -output-file-map "$INTENTS_BUILD/output-map.json" -o "$APP/Contents/MacOS/Dot" "${SOURCES[@]}" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework Vision -framework CryptoKit -framework EventKit \
  ${WHISPER_FLAGS[@]+"${WHISPER_FLAGS[@]}"}
cp target/release/dot-voice target/release/dot-search target/release/dot-fetch target/release/dot-safety "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources/Voice" "$APP/Contents/Resources/Runtime"
cp Resources/Runtime/dot_runtime.py Resources/Runtime/dot_process.py Resources/Runtime/dot_tls.py Resources/Runtime/splash.sb Resources/Runtime/splash-managed-listener-patch.json "$APP/Contents/Resources/Runtime/"
cp Resources/bundled-models.json "$APP/Contents/Resources/"
cp -R Resources/Research "$APP/Contents/Resources/"
cp Resources/Voice/BIONIC-LICENSE.txt "$APP/Contents/Resources/Voice/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# One minimum-OS policy (macOS 26.4), the same override build_complete.sh applies.
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 26.4' "$APP/Contents/Info.plist"
ICONSET=build/Icon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Icon.icns"
python3 -B scripts/package_app_intents.py extract --work-dir "$INTENTS_BUILD" --app "$APP" \
  --target "$TARGET" --deployment-target 26.4
python3 -B - "$APP" "$SOURCE_COMMIT" "$SOURCE_DIRTY" <<'PYCODE'
import json, pathlib, subprocess, sys
paths = ['src', 'Resources', 'scripts', 'Tests', 'Dot.xcodeproj', 'Package.swift', 'build.sh', 'icon.png', 'crates', 'Cargo.toml', 'Cargo.lock', 'packaging']
changed = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all', '--', *paths], text=True)
untracked = subprocess.check_output(['git', 'ls-files', '--others', '--', *paths], text=True)
current = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
record = {'commit': sys.argv[2], 'source_dirty': sys.argv[3] == 'true' or bool(changed.strip() or untracked.strip()) or current != sys.argv[2],
          'signing': 'ad-hoc', 'notarized': False, 'voice_protocol': 1, 'runtime_bundled': False,
          'models_bundled': False, 'llm_weights_download_on_first_launch': False}
(pathlib.Path(sys.argv[1]) / 'Contents/Resources/build-provenance.json').write_text(json.dumps(record, indent=2) + '\n')
PYCODE
# A cloud-synced checkout (Documents/Desktop under a File Provider) re-applies
# com.apple.FinderInfo/fileprovider attributes that make codesign reject the
# bundle with "resource fork, Finder information, or similar detritus not
# allowed". Clearing them is a no-op on an ordinary checkout.
xattr -cr "$APP" 2>/dev/null || true
# The File Provider can re-apply attributes between the clear and the sign, so
# retry the pair a bounded number of times instead of failing a good build.
attempt=1
until codesign --force --sign - "$APP" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -le 6 ] || {
        # The File Provider can keep re-applying attributes to the in-tree bundle for
        # minutes. This sign is a convenience copy: install_local.sh signs and verifies
        # the staged copy in TMPDIR (outside the sync root) with --strict, and fails the
        # install if THAT fails. Warn and continue instead of failing a healthy build.
        echo "warning: in-tree ad-hoc sign kept failing (detritus reapplied); the staged copy is signed and verified by install_local.sh" >&2
        break
    }
    sleep 1
    xattr -cr "$APP" 2>/dev/null || true
done
# Verify a byte-identical copy in TMPDIR: the synced checkout's File Provider can
# keep re-applying attributes to the in-tree bundle indefinitely, and verifying the
# clean copy proves the seal without racing the sync daemon.
VERIFY_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/dot-verify.XXXXXX")
cp -R "$APP" "$VERIFY_STAGE/Dot.app"
xattr -cr "$VERIFY_STAGE/Dot.app" 2>/dev/null || true
codesign --verify --strict "$VERIFY_STAGE/Dot.app"
rm -rf "$VERIFY_STAGE"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/dot-stage.XXXXXX")
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
python3 -B scripts/create_dmg.py "$STAGE" build/Dot.dmg
printf 'Built %s/build/Dot.dmg (development-only, no neural runtimes; ad-hoc signed, not notarized)\n' "$PWD"
