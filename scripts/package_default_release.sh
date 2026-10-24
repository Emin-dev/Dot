#!/bin/bash
# Build the DEFAULT downloadable app: runtime included, model excluded.
#
# The app verifies the signed manifest and downloads the exact Qwen3.8 27B Q4
# files on first launch (pinned Emin-dev/Dot split parts first, Hugging Face as a
# hash-checked fallback). No model bytes are shipped, so the DMG stays under the
# 2 GB GitHub asset limit.
#
# Requirements:
#   DOT_RUNTIME_PAYLOAD   audited `Offline` runtime directory
#   DOT_WHISPER_FRAMEWORK verified whisper.framework (the app must link it)
# Optional:
#   DOT_RELEASE_DIR       output directory (default build-public)
#   SIGN_IDENTITY         codesign identity (default "-", ad-hoc)
#
# This never launches the app, touches a microphone or downloads model weights.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DOT_RUNTIME_PAYLOAD:?Set DOT_RUNTIME_PAYLOAD to the audited Offline runtime directory}"
: "${DOT_WHISPER_FRAMEWORK:?Set DOT_WHISPER_FRAMEWORK to the verified whisper.framework}"
OUT="${DOT_RELEASE_DIR:-build-public}"
APP="build/Dot.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

fail() { echo "package_default_release: $*" >&2; exit 1; }
[ -d "$DOT_RUNTIME_PAYLOAD" ] || fail "no runtime payload at $DOT_RUNTIME_PAYLOAD"
[ -f "$DOT_WHISPER_FRAMEWORK/Modules/module.modulemap" ] || fail "no whisper.framework at $DOT_WHISPER_FRAMEWORK"
python3 -B scripts/audit_runtime_payload.py "$DOT_RUNTIME_PAYLOAD"

echo "==> building the current source with the verified runtime"
DOT_WHISPER_FRAMEWORK="$DOT_WHISPER_FRAMEWORK" bash build.sh
[ -f "$APP/Contents/Resources/model-parts.json" ] || fail "model-parts.json was not bundled"

echo "==> adding the audited runtime (no model payload)"
rm -rf "$APP/Contents/Resources/Offline"
/usr/bin/ditto "$DOT_RUNTIME_PAYLOAD" "$APP/Contents/Resources/Offline"
# Audit N1: the retired Python voice runtime (872 MB) never ships; the copy is
# slimmed and audited again, so every remaining file is still hashed.
python3 -B scripts/slim_runtime_payload.py "$APP/Contents/Resources/Offline"
python3 -B scripts/audit_runtime_payload.py --slim "$APP/Contents/Resources/Offline"
if [ -d "$APP/Contents/Resources/OfflineModels" ]; then
  fail "model payload leaked into the default app"
fi

echo "==> marking the public provenance"
python3 - "$APP/Contents/Resources/build-provenance.json" <<'PY'
import json, pathlib, subprocess, sys
path = pathlib.Path(sys.argv[1])
record = json.loads(path.read_text())
parts = json.loads((path.parent / 'model-parts.json').read_text())
tag = parts.get('release_tag') or ''
parts_ready = (parts.get('schema_version') == 1
               and parts.get('status') == 'ready'
               and bool(parts.get('parts'))
               and bool(tag)
               and str(parts.get('base_url', '')).startswith(
                   f'https://github.com/Emin-dev/Dot/releases/download/{tag}/'))
record.update({
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()),
    'runtime_bundled': True,
    'models_bundled': False,
    'models_downloaded': False,
    'llm_weights_download_on_first_launch': True,
    'model_primary': ('pinned Emin-dev/Dot release parts' if parts_ready
                      else 'pinned Hugging Face revisions (Emin-dev/Dot parts pending)'),
    'model_fallback': ('pinned Hugging Face revisions, SHA-256 checked'
                       if parts_ready else 'n/a: fallback is the active route'),
})
path.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
PY

echo "==> signing for the App Sandbox"
cp scripts/uninstall-dot.sh "$APP/Contents/Resources/uninstall-dot.sh"
xattr -cr "$APP"
bash scripts/sign_sandbox_app.sh "$APP" "$SIGN_IDENTITY"

echo "==> packaging $OUT/Dot.dmg"
mkdir -p "$OUT"
mkdir -p .tmp
STAGE="$(mktemp -d "$PWD/.tmp/dot-default.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/Dot.app"
rm -f "$OUT/Dot.dmg" "$OUT/Dot.dmg.sha256"
python3 -B scripts/create_dmg.py "$STAGE" "$OUT/Dot.dmg"
hdiutil verify -quiet "$OUT/Dot.dmg"
SIZE=$(stat -f%z "$OUT/Dot.dmg")
[ "$SIZE" -lt 2000000000 ] || fail "DMG is $SIZE bytes; GitHub rejects assets at 2 GB"
(cd "$OUT" && shasum -a 256 Dot.dmg > Dot.dmg.sha256)
ls -lh "$OUT/Dot.dmg" "$OUT/Dot.dmg.sha256"
echo "PASS: default app packaged without model weights ($SIZE bytes)"
