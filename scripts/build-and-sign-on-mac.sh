#!/bin/bash
# Build Dot on this Mac, sign it with an Apple Development identity, install it
# into ~/Applications and open it. The app is sandboxed; no administrator is used.
#
# This is the owner-only fallback when the public ad-hoc DMG is blocked by
# Gatekeeper. It is not a public release path: an Apple Development signature
# only satisfies Gatekeeper on the Mac that owns the signing certificate.
# A warning-free double-click for everyone still requires Developer ID
# notarisation (paid Apple account, owner-only).
#
# Usage:
#   bash scripts/build-and-sign-on-mac.sh
#
# Environment:
#   DOT_INSTALL_DIR   destination app directory (default: ~/Applications)
#   SIGN_IDENTITY     override the detected codesigning identity
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL_DIR="${DOT_INSTALL_DIR:-$HOME/Applications}"
APP="$INSTALL_DIR/Dot.app"

fail() { echo "build-and-sign-on-mac: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ "$(uname -s)" = "Darwin" ] || fail "this script only runs on macOS"
command -v xcrun >/dev/null 2>&1 || fail "Xcode command line tools are required"
command -v cargo >/dev/null 2>&1 || fail "cargo is required to build the Rust runtime"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1 || true)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
    echo "note: no Apple Development identity found; falling back to an ad-hoc signature."
    echo "note: an ad-hoc build may still be blocked by Gatekeeper on this Mac."
else
    echo "==> signing identity: $SIGN_IDENTITY"
fi

COMPLETE=""
for candidate in "$APP" "$HOME/Applications/Dot.app" "/Applications/Dot.app" "build/Dot.app"; do
    if [ -d "$candidate/Contents/Resources/Offline" ] \
        && [ -d "$candidate/Contents/Resources/OfflineModels" ]; then
        COMPLETE="$candidate"
        break
    fi
done

if [ -n "$COMPLETE" ]; then
    echo "==> found a complete local payload at $COMPLETE"
    if [ "$COMPLETE" != "$APP" ]; then
        echo "==> staging the existing complete app at $APP so the upgrade can clone its payload"
        rm -rf "$APP"
        mkdir -p "$INSTALL_DIR"
        ditto "$COMPLETE" "$APP"
    fi
    # install_local.sh rebuilds the source, clones Offline plus OfflineModels,
    # signs with the selected identity, swaps the app in and launches it.
    SIGN_IDENTITY="$SIGN_IDENTITY" DOT_INSTALL_PATH="$APP" bash scripts/install_local.sh
else
    echo "==> no complete local payload found; building the source app and embedding"
    echo "    a speech recognizer from an existing installation when one exists"
    WHISPER=""
    for candidate in "$APP" "$HOME/Applications/Dot.app" "/Applications/Dot.app"; do
        if [ -f "$candidate/Contents/Frameworks/whisper.framework/Modules/module.modulemap" ]; then
            WHISPER="$candidate/Contents/Frameworks/whisper.framework"
            break
        fi
    done
    if [ -n "$WHISPER" ]; then
        DOT_WHISPER_FRAMEWORK="$WHISPER" bash build.sh
    else
        bash build.sh
    fi
    [ -x build/Dot.app/Contents/MacOS/Dot ] || fail "build.sh produced no executable"

    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dot-sign-install.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    ditto build/Dot.app "$STAGE/Dot.app"
    xattr -cr "$STAGE/Dot.app"
    bash scripts/sign_sandbox_app.sh "$STAGE/Dot.app" "$SIGN_IDENTITY" || fail "staged signature did not verify"

    mkdir -p "$INSTALL_DIR"
    osascript -e 'tell application "Dot" to quit' >/dev/null 2>&1 || true
    sleep 2
    if pgrep -x Dot >/dev/null 2>&1; then pkill -x Dot >/dev/null 2>&1 || true; sleep 2; fi
    rm -rf "$APP"
    ditto "$STAGE/Dot.app" "$APP"
fi

codesign --verify --strict "$APP" || fail "installed signature did not verify"
DETAIL="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
echo "$DETAIL" | sed -n '1,12p'
open "$APP" || fail "could not open $APP"
sleep 5
pgrep -x Dot >/dev/null 2>&1 || fail "Dot did not stay running"
pass "Dot built, signed, installed at $APP and running"
echo "PASS: this Mac can now open Dot because the app is signed by its own Apple Development identity."
echo "PASS: a no-warning download for every Mac still needs Developer ID notarisation (owner-only)."
