#!/bin/bash
# Sign a Dot.app for the Apple App Sandbox with the minimum entitlements.
#
# Nested code is signed first, then the app with Resources/Dot.entitlements and
# the hardened runtime. The final signature is verified and its entitlements are
# read back so a packaging mistake fails here instead of on the owner's Mac.
#
# Usage: bash scripts/sign_sandbox_app.sh <Dot.app> [identity]
#   identity defaults to "-" (ad-hoc). Never uses --deep on the finished app.
set -euo pipefail
APP="${1:?usage: sign_sandbox_app.sh <Dot.app> [identity]}"
SIGN_IDENTITY="${2:--}"
ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/Resources/Dot.entitlements"

fail() { echo "sign_sandbox_app: $*" >&2; exit 1; }
[ -d "$APP" ] || fail "no app at $APP"
[ -f "$ENTITLEMENTS" ] || fail "missing $ENTITLEMENTS"

TIMESTAMP=()
if [ "$SIGN_IDENTITY" != "-" ]; then
    TIMESTAMP=(--timestamp)
fi

# Deep-sign the one embedded framework's nested code before sealing the app.
if [ -d "$APP/Contents/Frameworks/whisper.framework" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime \
        ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --deep "$APP/Contents/Frameworks/whisper.framework"
fi

# Every executable beside the app binary is Dot-owned runtime code. Sign each
# explicitly so sandbox inheritance and Gatekeeper validation see valid seals.
for binary in "$APP/Contents/MacOS/"*; do
    [ -f "$binary" ] && [ -x "$binary" ] || continue
    [ "$(basename "$binary")" = "Dot" ] && continue
    codesign --force --sign "$SIGN_IDENTITY" --options runtime \
        ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} "$binary"
done

codesign --force --sign "$SIGN_IDENTITY" --options runtime \
    ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict "$APP"
codesign --verify --strict "$APP/Contents/MacOS/Dot"

ENTITLEMENTS_READBACK="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
case "$ENTITLEMENTS_READBACK" in
    *com.apple.security.app-sandbox*) ;;
    *) fail "the signed app does not carry com.apple.security.app-sandbox" ;;
esac
case "$ENTITLEMENTS_READBACK" in
    *com.apple.security.files.user-selected.read-write*) ;;
    *) fail "the signed app does not carry user-selected file access" ;;
esac
echo "PASS: sandbox entitlements and hardened runtime signed and verified"
