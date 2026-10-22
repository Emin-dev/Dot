#!/bin/bash
# Dot one-line installer for macOS.
#
# Documented use (first line of README.txt, TEST_TODAY.md and the release notes):
#   curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/install-dot.sh | bash
#
# curl adds no com.apple.quarantine attribute. The script downloads every
# published part, verifies each SHA-256, joins the parts when the release uses
# split parts, mounts the DMG, installs Dot.app into ~/Applications (creating it
# only when missing), clears quarantine from Dot's staged bundle only, verifies
# the sandbox entitlements and signature, then opens Dot. It is idempotent. It
# never uses sudo and
# never writes to /Applications, system settings, profiles or shell rc files.
#
# Environment (all optional):
#   DOT_RELEASE_BASE    asset base URL (default: this repository's latest release)
#   DOT_INSTALL_DIR     destination application directory (default: ~/Applications)
#   DOT_DMG             use an already-downloaded DMG instead of downloading one
#   DOT_DMG_SHA256      expected SHA-256 for DOT_DMG (default: read the release)
#   DOT_TEST_QUARANTINE set to 1 to mark the staged app before clearing it (CI)
set -euo pipefail

RELEASE_BASE="${DOT_RELEASE_BASE:-https://github.com/Emin-dev/Dot/releases/latest/download}"
INSTALL_DIR="${DOT_INSTALL_DIR:-$HOME/Applications}"
APP="$INSTALL_DIR/Dot.app"
ATTR="com.apple.quarantine"
MARKER="$INSTALL_DIR/.dot-install-created-applications"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
need() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

[ "$(uname -s)" = "Darwin" ] || fail "this installer only runs on macOS"

# Dot refuses to start below its minimum. Say so before the long download, also
# on macOS versions that would refuse the app before Dot can show its own message.
# This only warns: the release gate installs on a smaller hosted Mac on purpose.
check_minimum() {
    local os major chip memory mem_gb reasons=""
    os="$(sw_vers -productVersion 2>/dev/null || echo 0)"
    major="${os%%.*}"
    chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    memory="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    mem_gb=$(( (memory + 536870912) / 1073741824 ))
    [ "${major:-0}" -ge 27 ] 2>/dev/null || reasons="$reasons macOS $os (27.0 or newer needed);"
    [ "$mem_gb" -ge 48 ] || reasons="$reasons $mem_gb GB memory (48 GB needed);"
    case "$chip" in
        *"Apple M5 Pro"*|*"Apple M5 Max"*|*"Apple M5 Ultra"*|*"Apple M"[6-9]*|*"Apple M"[1-9][0-9]*) ;;
        *) reasons="$reasons $chip (Apple M5 Pro class or newer needed);" ;;
    esac
    if [ -n "$reasons" ]; then
        echo "WARNING: Dot needs Apple Silicon M5 Pro class or newer, 48 GB Unified Memory and macOS 27.0 or newer. This Mac has:$reasons Dot installs, but it will show this message and not start here." >&2
    fi
}
check_minimum
need curl
need shasum
need hdiutil
need ditto
need xattr
need codesign
need open

case "$INSTALL_DIR" in
    /*) ;;
    *) fail "DOT_INSTALL_DIR must be an absolute path" ;;
esac
[ "$INSTALL_DIR" != "/Applications" ] \
    || fail "Dot installs per-user; leave DOT_INSTALL_DIR unset (default: ~/Applications)"
[ -w "$(dirname "$INSTALL_DIR")" ] \
    || fail "cannot create $INSTALL_DIR without an administrator; this installer never uses sudo"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dot-install.XXXXXX")"
MNT="$WORK/mnt"
DMG="$WORK/Dot.dmg"
MOUNTED=0
STAGED=""
APP_CREATED_DIR=0
INSTALLED=0
cleanup() {
    if [ "$MOUNTED" = "1" ]; then
        hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
    fi
    if [ -n "$STAGED" ]; then
        rm -rf "$STAGED" >/dev/null 2>&1 || true
    fi
    # A failed install must not leave the directory or marker it created.
    if [ "$APP_CREATED_DIR" = "1" ] && [ "$INSTALLED" = "0" ]; then
        rm -f "$MARKER" >/dev/null 2>&1 || true
        rmdir "$INSTALL_DIR" >/dev/null 2>&1 || true
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

expected_dmg_sha="${DOT_DMG_SHA256:-}"

if [ -n "${DOT_DMG:-}" ]; then
    [ -f "$DOT_DMG" ] || fail "DOT_DMG does not exist: $DOT_DMG"
    DMG="$DOT_DMG"
    if [ -z "$expected_dmg_sha" ]; then
        download "$RELEASE_BASE/Dot.dmg.sha256" "$WORK/Dot.dmg.sha256"
        expected_dmg_sha="$(awk 'NR == 1 { print $1 }' "$WORK/Dot.dmg.sha256")"
    fi
    pass "using the provided DMG $DMG"
else
    PARTS_LIST="$WORK/Dot.dmg.parts.sha256"
    if curl -fsSL --retry 3 -o "$PARTS_LIST" "$RELEASE_BASE/Dot.dmg.parts.sha256"; then
        PARTS=()
        while read -r digest name; do
            [ -n "${digest:-}" ] || continue
            case "$name" in
                Dot.dmg.part[0-9][0-9][0-9]) ;;
                *) fail "unsafe or unexpected part name: ${name:-<empty>}" ;;
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
        pass "Dot.dmg downloaded with curl (no quarantine added)"
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

if [ "$(hdiutil info | grep -cF "on $MNT " || true)" -gt 0 ]; then
    hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
fi
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" -quiet \
    || fail "could not mount $DMG"
MOUNTED=1
[ -d "$MNT/Dot.app" ] || fail "Dot.app is missing from the DMG"
[ -x "$MNT/Dot.app/Contents/MacOS/Dot" ] || fail "Dot.app has no executable"
pass "mounted the DMG"

if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR" || fail "could not create $INSTALL_DIR"
    APP_CREATED_DIR=1
fi
if [ "$APP_CREATED_DIR" = "1" ]; then
    : > "$MARKER" || fail "could not record the installer-created $INSTALL_DIR"
fi

STAGED="$INSTALL_DIR/.Dot.app.installing.$$"
rm -rf "$STAGED"
ditto "$MNT/Dot.app" "$STAGED" || fail "could not copy Dot.app"
pass "Dot.app copied to $INSTALL_DIR"

# Quarantine is cleared from Dot's own staged bundle only. Nothing else on the
# Mac is touched with xattr, including the downloaded DMG outside the temp dir.
if [ "${DOT_TEST_QUARANTINE:-0}" = "1" ]; then
    xattr -w "$ATTR" "0081;$(printf '%x' "$(date +%s)");Safari;" "$STAGED"
    xattr -p "$ATTR" "$STAGED" >/dev/null 2>&1 \
        || fail "could not set the CI test quarantine attribute"
    pass "test quarantine attribute set on the staged app"
fi
xattr -dr "$ATTR" "$STAGED" || fail "could not clear quarantine from the staged app"
if xattr -p "$ATTR" "$STAGED" >/dev/null 2>&1; then
    fail "com.apple.quarantine is still present on $STAGED"
fi
pass "quarantine cleared from Dot's staged bundle"

ENTITLEMENTS="$(codesign -d --entitlements - "$STAGED" 2>/dev/null || true)"
case "$ENTITLEMENTS" in
    *com.apple.security.app-sandbox*) ;;
    *) fail "the downloaded Dot.app is not signed for the Apple App Sandbox" ;;
esac
case "$ENTITLEMENTS" in
    *com.apple.security.network.client*) ;;
    *) fail "the downloaded Dot.app is missing network.client" ;;
esac
case "$ENTITLEMENTS" in
    *com.apple.security.files.user-selected.read-write*) ;;
    *) fail "the downloaded Dot.app is missing user-selected file access" ;;
esac
codesign --verify --deep --strict "$STAGED" || fail "codesign --verify --deep --strict failed"
pass "sandbox entitlements and code signature verified"

osascript -e 'tell application "Dot" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Dot >/dev/null 2>&1 || break
    sleep 1
done
if pgrep -x Dot >/dev/null 2>&1; then
    pkill -9 -x Dot >/dev/null 2>&1 || true
    sleep 1
fi
if pgrep -x Dot >/dev/null 2>&1; then
    fail "Dot is still running; quit it and run the installer again"
fi

rm -rf "$APP" || fail "could not replace $APP"
mv "$STAGED" "$APP" || fail "could not install $APP"
STAGED=""
INSTALLED=1
codesign --verify --deep --strict "$APP" || fail "the installed signature did not verify"
pass "Dot.app installed at $APP"

# v1.1.1 installed to /Applications. Remove only our own legacy bundle after the
# new per-user app is safely in place; never use sudo or delete another Dot.app.
LEGACY_APP="/Applications/Dot.app"
if [ -e "$LEGACY_APP" ]; then
    LEGACY_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_APP/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$LEGACY_ID" = "app.dot.local" ]; then
        if [ -w "$LEGACY_APP" ] || [ -w /Applications ]; then
            rm -rf "$LEGACY_APP" || fail "could not remove the legacy /Applications/Dot.app"
            pass "removed the legacy /Applications/Dot.app"
        else
            echo "WARNING: legacy /Applications/Dot.app is not writable; remove it in Finder (no sudo)." >&2
        fi
    fi
fi

hdiutil detach "$MNT" -quiet || fail "could not detach the DMG"
MOUNTED=0
pass "DMG detached"

# Capture macOS' own words when it refuses to start the app. `open` returns
# stderr from LaunchServices; spctl gives the Gatekeeper verdict in plain text.
if ! OPEN_ERROR="$(open "$APP" 2>&1)"; then
    SPCTL="$(spctl --assess -vv "$APP" 2>&1 || true)"
    echo "macOS refused to open Dot: ${OPEN_ERROR:-no detail from open}" >&2
    if [ -n "$SPCTL" ]; then echo "Gatekeeper: $SPCTL" >&2; fi
    fail "macOS blocked the first open; do not change any System Setting. Send these lines back."
fi
for _ in $(seq 1 45); do
    pgrep -x Dot >/dev/null 2>&1 && break
    sleep 1
done
if ! pgrep -x Dot >/dev/null 2>&1; then
    SPCTL="$(spctl --assess -vv "$APP" 2>&1 || true)"
    echo "macOS reported no error from open, but Dot exited immediately." >&2
    if [ -n "$SPCTL" ]; then echo "Gatekeeper: $SPCTL" >&2; fi
    fail "Dot did not stay running after open; the exact diagnostics are above"
fi
pass "Dot launched"
echo "PASS: Dot is installed at $APP"
echo "PASS: Remove it with: curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/uninstall-dot.sh | bash"
