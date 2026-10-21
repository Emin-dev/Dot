#!/bin/bash
# Dot one-line installer for macOS.
#
# Documented use (first line of README.txt, TEST_TODAY.md and the release notes):
#   curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/install-dot.sh | bash
#
# curl adds no com.apple.quarantine attribute, so the downloaded DMG is clean.
# The script downloads every published part, verifies each SHA-256, joins the
# parts when the release uses split parts, mounts the DMG, installs Dot.app to
# /Applications, clears quarantine, verifies the ad-hoc signature deeply, then
# opens Dot. It is idempotent: a re-run downloads again, replaces the app safely
# and preserves nothing from a broken previous install.
#
# Environment (all optional):
#   DOT_RELEASE_BASE    asset base URL (default: this repository's latest release)
#   DOT_INSTALL_DIR     destination application directory (default: /Applications)
#   DOT_DMG             use an already-downloaded DMG instead of downloading one
#   DOT_DMG_SHA256      expected SHA-256 for DOT_DMG (default: read the release)
#   DOT_TEST_QUARANTINE set to 1 to mark the staged app before clearing it (CI)
set -euo pipefail

RELEASE_BASE="${DOT_RELEASE_BASE:-https://github.com/Emin-dev/Dot/releases/latest/download}"
INSTALL_DIR="${DOT_INSTALL_DIR:-/Applications}"
APP="$INSTALL_DIR/Dot.app"
ATTR="com.apple.quarantine"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
need() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

[ "$(uname -s)" = "Darwin" ] || fail "this installer only runs on macOS"
need curl
need shasum
need hdiutil
need ditto
need xattr
need codesign
need open

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dot-install.XXXXXX")"
MNT="$WORK/mnt"
DMG="$WORK/Dot.dmg"
MOUNTED=0
STAGED=""
cleanup() {
    if [ "$MOUNTED" = "1" ]; then
        hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
    fi
    if [ -n "$STAGED" ]; then
        rm -rf "$STAGED" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
mkdir -p "$MNT"

download() {
    local url="$1" destination="$2"
    echo "==> downloading $(basename "$url")"
    curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 20 -o "$destination" "$url" \
        || fail "download failed: $url"
}

expected_dmg_sha=""
if [ -n "${DOT_DMG_SHA256:-}" ]; then
    expected_dmg_sha="$DOT_DMG_SHA256"
fi

if [ -n "${DOT_DMG:-}" ]; then
    [ -f "$DOT_DMG" ] || fail "DOT_DMG does not exist: $DOT_DMG"
    DMG="$DOT_DMG"
    if [ -z "$expected_dmg_sha" ]; then
        download "$RELEASE_BASE/Dot.dmg.sha256" "$WORK/Dot.dmg.sha256"
        expected_dmg_sha="$(awk 'NR == 1 { print $1 }' "$WORK/Dot.dmg.sha256")"
    fi
    pass "using the provided DMG $DMG (curl never adds quarantine)"
else
    PARTS_LIST="$WORK/Dot.dmg.parts.sha256"
    if curl -fsSL --retry 3 -o "$PARTS_LIST" "$RELEASE_BASE/Dot.dmg.parts.sha256"; then
        # Split release: download every part named by the signed-by-hash list,
        # verify each part, then join them in that exact order.
        PARTS=()
        while read -r digest name; do
            [ -n "${digest:-}" ] || continue
            case "$name" in
                Dot.dmg.part[0-9][0-9][0-9]) ;;
                *) fail "unsafe or unexpected part name in Dot.dmg.parts.sha256: ${name:-<empty>}" ;;
            esac
            [ "${#digest}" -eq 64 ] || fail "invalid SHA-256 for part $name"
            download "$RELEASE_BASE/$name" "$WORK/$name"
            PARTS+=("$WORK/$name")
        done < "$PARTS_LIST"
        [ "${#PARTS[@]}" -gt 0 ] || fail "the parts list is empty"
        (cd "$WORK" && shasum -a 256 -c Dot.dmg.parts.sha256) \
            || fail "part SHA-256 verification failed"
        pass "every part SHA-256 verified (${#PARTS[@]} parts)"
        : > "$DMG"
        for part in "${PARTS[@]}"; do
            cat "$part" >> "$DMG"
        done
        pass "parts joined into Dot.dmg"
        download "$RELEASE_BASE/Dot.dmg.sha256" "$WORK/Dot.dmg.sha256"
        expected_dmg_sha="$(awk 'NR == 1 { print $1 }' "$WORK/Dot.dmg.sha256")"
    else
        download "$RELEASE_BASE/Dot.dmg" "$DMG"
        download "$RELEASE_BASE/Dot.dmg.sha256" "$WORK/Dot.dmg.sha256"
        expected_dmg_sha="$(awk 'NR == 1 { print $1 }' "$WORK/Dot.dmg.sha256")"
        pass "Dot.dmg downloaded with curl (no quarantine attribute added)"
    fi
fi

case "$expected_dmg_sha" in
    [0-9a-f]*) ;;
    *) fail "the release did not provide a valid Dot.dmg SHA-256" ;;
esac
[ "${#expected_dmg_sha}" -eq 64 ] || fail "the release Dot.dmg SHA-256 is not 64 hex characters"
ACTUAL_DMG_SHA="$(shasum -a 256 "$DMG" | awk '{ print $1 }')"
[ "$ACTUAL_DMG_SHA" = "$expected_dmg_sha" ] \
    || fail "Dot.dmg SHA-256 mismatch (expected $expected_dmg_sha, got $ACTUAL_DMG_SHA)"
pass "Dot.dmg SHA-256 verified ($ACTUAL_DMG_SHA)"

# A browser-downloaded DMG may carry quarantine; this script handles both cases.
xattr -d "$ATTR" "$DMG" >/dev/null 2>&1 || true

if [ "$(hdiutil info | grep -cF "on $MNT " || true)" -gt 0 ]; then
    hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
fi
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" -quiet \
    || fail "could not mount $DMG"
MOUNTED=1
[ -d "$MNT/Dot.app" ] || fail "Dot.app is missing from the DMG"
[ -x "$MNT/Dot.app/Contents/MacOS/Dot" ] || fail "Dot.app has no executable"
pass "mounted the DMG"

SUDO=()
if [ -w "$INSTALL_DIR" ] && { [ ! -e "$APP" ] || [ -w "$APP" ]; }; then
    :
else
    echo "==> $INSTALL_DIR needs administrator permission"
    if sudo -n true 2>/dev/null; then
        SUDO=(sudo -n)
    elif sudo -v </dev/tty 2>/dev/null; then
        SUDO=(sudo -n)
    else
        fail "cannot write $INSTALL_DIR without an administrator; set DOT_INSTALL_DIR to a writable folder or run the installer from an admin account"
    fi
fi

"${SUDO[@]}" mkdir -p "$INSTALL_DIR"
STAGED="$INSTALL_DIR/.Dot.app.installing.$$"
"${SUDO[@]}" rm -rf "$STAGED"
"${SUDO[@]}" ditto "$MNT/Dot.app" "$STAGED" || fail "could not copy Dot.app"
pass "Dot.app copied to $INSTALL_DIR"

if [ "${DOT_TEST_QUARANTINE:-0}" = "1" ]; then
    "${SUDO[@]}" xattr -w "$ATTR" "0081;$(printf '%x' "$(date +%s)");Safari;" "$STAGED"
    "${SUDO[@]}" xattr -p "$ATTR" "$STAGED" >/dev/null 2>&1 \
        || fail "could not set the CI test quarantine attribute"
    pass "test quarantine attribute set on the staged app"
fi

"${SUDO[@]}" xattr -dr "$ATTR" "$STAGED" || fail "could not clear quarantine"
if "${SUDO[@]}" xattr -p "$ATTR" "$STAGED" >/dev/null 2>&1; then
    fail "com.apple.quarantine is still present on $APP"
fi
pass "quarantine cleared from Dot.app"

codesign --verify --deep --strict "$STAGED" || fail "codesign --verify --deep --strict failed"
pass "ad-hoc code signature verified (--deep --strict)"

osascript -e 'tell application "Dot" to quit' >/dev/null 2>&1 || true
sleep 2
if pgrep -x Dot >/dev/null 2>&1; then
    pkill -x Dot >/dev/null 2>&1 || true
    sleep 2
fi

"${SUDO[@]}" rm -rf "$APP" || fail "could not replace $APP"
"${SUDO[@]}" mv "$STAGED" "$APP" || fail "could not install $APP"
STAGED=""
codesign --verify --deep --strict "$APP" || fail "the installed signature did not verify"
pass "Dot.app installed at $APP"

hdiutil detach "$MNT" -quiet || fail "could not detach the DMG"
MOUNTED=0
pass "DMG detached"

open "$APP" || fail "could not open $APP"
pass "Dot launched"
echo "PASS: Dot is installed. First launch may take a minute while it verifies its runtime."
echo "PASS: If macOS still shows a warning, use System Settings > Privacy & Security > Open Anyway."
