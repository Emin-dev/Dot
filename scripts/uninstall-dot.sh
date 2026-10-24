#!/bin/bash
# Remove Dot and every trace it left outside its own bundle.
#
# One line (same release URL style as the installer):
#   curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/uninstall-dot.sh | bash
#
# It never uses sudo. It removes the per-user app, the App Sandbox container,
# group containers, caches, saved state, HTTP/WebKit stores, preferences, Dot's
# legacy Application Support folder, its LaunchServices registration, and resets
# the app's privacy approvals with tccutil. It removes ~/Applications only when
# the installer created it and nothing else is left in it. The app is removed
# only when its bundle id is Dot's, and a folder or crash report with the generic
# name "Dot" only when it holds Dot's own files.
set -euo pipefail

BUNDLE_ID="${DOT_BUNDLE_ID:-app.dot.local}"
INSTALL_DIR="${DOT_INSTALL_DIR:-$HOME/Applications}"
APP="$INSTALL_DIR/Dot.app"
MARKER="$INSTALL_DIR/.dot-install-created-applications"
LEGACY_APP="/Applications/Dot.app"

fail() { echo "FAIL: $*" >&2; exit 1; }
bundle_id_of() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}
# Audit S12: the id names every folder removed below, so it must be a plain
# reverse-DNS name: a letter, then letters, digits, dots and hyphens, never "..".
# (DOT_BUNDLE_ID=../../Documents would otherwise name ~/Documents.)
valid_bundle_id() {
    local LC_ALL=C
    [[ "$1" =~ ^[A-Za-z][A-Za-z0-9.-]*$ ]] && [[ "$1" != *..* ]]
}

[ "$(uname -s)" = "Darwin" ] || fail "this uninstaller only runs on macOS"
valid_bundle_id "$BUNDLE_ID" || fail "DOT_BUNDLE_ID is not a valid bundle id: $BUNDLE_ID"

# Audit S12: remove the app only when it is Dot, by its bundle id.
APP_IS_DOT=0
APP_IS_OTHER=0
if [ -e "$APP" ] || [ -L "$APP" ]; then
    APP_ID="$(bundle_id_of "$APP")"
    if [ "$APP_ID" = "$BUNDLE_ID" ]; then
        APP_IS_DOT=1
    else
        APP_IS_OTHER=1
        echo "note: leaving $APP alone; its bundle id is ${APP_ID:-missing}, not $BUNDLE_ID"
    fi
fi

LEGACY_IS_DOT=0
if [ -d "$LEGACY_APP" ] && [ "$(bundle_id_of "$LEGACY_APP")" = "$BUNDLE_ID" ]; then
    LEGACY_IS_DOT=1
fi

# Quit the app without asking macOS for anything. The app has no background
# helper, LaunchAgent or login item to unload. Nothing is quit when another app
# sits at Dot's path and no Dot install is found (audit S12); a Dot still running
# after its app was deleted is quit as before.
if [ "$APP_IS_OTHER" != "1" ] || [ "$LEGACY_IS_DOT" = "1" ]; then
osascript -e 'tell application "Dot" to quit' >/dev/null 2>&1 || true
pkill -x Dot >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Dot >/dev/null 2>&1 || break
    sleep 1
done
if pgrep -x Dot >/dev/null 2>&1; then
    pkill -9 -x Dot >/dev/null 2>&1 || true
    sleep 1
fi
if pgrep -x Dot >/dev/null 2>&1; then
    fail "Dot is still running; quit it and run this again"
fi
# Dot's bundled runtime children share the app path, never the owner's other apps.
for pattern in "$APP/Contents/" "$HOME/Applications/Dot.app/Contents/"; do
    pkill -f "$pattern" >/dev/null 2>&1 || true
done
fi

# Unregister before deleting so LaunchServices does not keep a stale app record.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    if [ "$APP_IS_DOT" = "1" ]; then
        "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    fi
    if [ "$LEGACY_IS_DOT" = "1" ]; then
        "$LSREGISTER" -u "$LEGACY_APP" >/dev/null 2>&1 || true
    fi
fi

if [ "$APP_IS_DOT" = "1" ]; then
    rm -rf "$APP" || fail "could not remove $APP"
fi
if [ -e "$LEGACY_APP" ]; then
    LEGACY_ID="$(bundle_id_of "$LEGACY_APP")"
    if [ "$LEGACY_ID" != "$BUNDLE_ID" ]; then
        echo "note: leaving $LEGACY_APP alone; its bundle id is not $BUNDLE_ID"
    elif [ -w "$LEGACY_APP" ] || [ -w /Applications ]; then
        rm -rf "$LEGACY_APP" || fail "could not remove the legacy install at $LEGACY_APP"
    else
        fail "a legacy install remains at $LEGACY_APP and needs an administrator; this script never uses sudo"
    fi
fi

# Dot keeps receipts and recovery copies in a private .dot-actions folder inside
# each folder the owner chose for file actions, and lists those folders in its
# container. Remove only a .dot-actions folder that Dot owns (its lock and ledger
# files), never a symlink, never anything else in the owner's folder.
ACTION_FOLDERS="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/Dot/action-folders.txt"
if [ -f "$ACTION_FOLDERS" ]; then
    while IFS= read -r folder || [ -n "$folder" ]; do
        case "$folder" in /*) ;; *) continue ;; esac
        target="$folder/.dot-actions"
        [ -d "$target" ] && [ ! -L "$target" ] && [ -O "$target" ] || continue
        [ -f "$target/owner.lock" ] || continue
        rm -rf "$target" || fail "could not remove $target"
    done < "$ACTION_FOLDERS"
fi

# A Dock tile the owner pinned would stay behind as a "?" icon. Remove only Dot's
# tile, through cfprefsd, and restart the Dock so it takes effect.
DOCK_STATE="$(defaults read com.apple.dock 2>/dev/null || true)"
if [[ "$DOCK_STATE" == *"$BUNDLE_ID"* ]]; then
    DOCK_DIR="$(mktemp -d -t dot-dock)"
    DOCK_PLIST="$DOCK_DIR/dock.plist"
    defaults export com.apple.dock "$DOCK_PLIST"
    for section in persistent-apps recent-apps; do
        index=0
        while /usr/libexec/PlistBuddy -c "Print :$section:$index" "$DOCK_PLIST" >/dev/null 2>&1; do
            id="$(/usr/libexec/PlistBuddy -c "Print :$section:$index:tile-data:bundle-identifier" "$DOCK_PLIST" 2>/dev/null || true)"
            if [ "$id" = "$BUNDLE_ID" ]; then
                /usr/libexec/PlistBuddy -c "Delete :$section:$index" "$DOCK_PLIST"
            else
                index=$((index + 1))
            fi
        done
    done
    defaults import com.apple.dock "$DOCK_PLIST"
    rm -rf "$DOCK_DIR"
    killall Dock >/dev/null 2>&1 || true
fi

# A browser download of Dot leaves a row in the quarantine-events history. Delete
# only rows that point at this repository's releases.
QUARANTINE_DB="$HOME/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
if [ -f "$QUARANTINE_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
    WHERE="LSQuarantineDataURLString LIKE '%github.com/Emin-dev/Dot/%' OR LSQuarantineOriginURLString LIKE '%github.com/Emin-dev/Dot/%'"
    if [ "$(sqlite3 "$QUARANTINE_DB" "SELECT count(*) FROM LSQuarantineEvent WHERE $WHERE;" 2>/dev/null || echo 0)" != "0" ]; then
        sqlite3 "$QUARANTINE_DB" "DELETE FROM LSQuarantineEvent WHERE $WHERE;" || fail "could not remove Dot's download history rows"
    fi
fi

# Every location the app, TCC and WebKit can create for this bundle id.
rm -rf \
    "$HOME/Library/Containers/$BUNDLE_ID" \
    "$HOME/Library/Group Containers/group.$BUNDLE_ID" \
    "$HOME/Library/Group Containers/$BUNDLE_ID" \
    "$HOME/Library/Biome/sets/Default/App.Shortcut.Phrase/sourceIdentifier=$BUNDLE_ID" \
    "$HOME/Library/Application Support/$BUNDLE_ID" \
    "$HOME/Library/Application Scripts/$BUNDLE_ID" \
    "$HOME/Library/Caches/$BUNDLE_ID" \
    "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
    "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" \
    "$HOME/Library/WebKit/$BUNDLE_ID" \
    "$HOME/Library/WebKit/com.apple.WebKit.WebContent/$BUNDLE_ID" \
    "$HOME/Library/Cookies/$BUNDLE_ID.binarycookies" \
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
    "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
    "$HOME/Library/Logs/$BUNDLE_ID" \
    "$HOME/Library/Autosave Information/$BUNDLE_ID" \
    "$HOME/Library/Application Support/Caches/$BUNDLE_ID" \
    "$HOME/Library/Caches/com.apple.helpd/Generated/$BUNDLE_ID" \
    || fail "could not remove one of Dot's data folders"

# Audit S12: "Dot" is a generic name another app may use too. Remove these two
# folders only when they hold a file Dot itself writes there (the unsandboxed
# v1.1.1 and older kept its data in Application Support/Dot); otherwise say so.
REMOVED_DOT_FOLDERS=()
remove_dot_folder() {
    local folder="$1" marker
    shift
    [ -e "$folder" ] || [ -L "$folder" ] || return 0
    if [ -d "$folder" ] && [ ! -L "$folder" ]; then
        for marker in "$@"; do
            if [ -e "$folder/$marker" ]; then
                rm -rf "$folder" || fail "could not remove $folder"
                REMOVED_DOT_FOLDERS+=("$folder")
                return 0
            fi
        done
    fi
    echo "note: leaving $folder alone; it holds none of Dot's own files"
}
remove_dot_folder "$HOME/Library/Application Support/Dot" \
    install-id github.token Logs/dot_chat_log.txt Logs/dot-sync.log Logs/upload-queue.json \
    dot-health.json .screen_permission_configured action-folders.txt
remove_dot_folder "$HOME/Library/Logs/Dot" dot_chat_log.txt dot-sync.log

# Crash-reporter records and any launch agent named for Dot (Dot installs none).
for extra in "$HOME/Library/Application Support/CrashReporter/Dot_"*.plist \
             "$HOME/Library/LaunchAgents/$BUNDLE_ID"*.plist; do
    [ -e "$extra" ] || continue
    case "$extra" in
        */LaunchAgents/*) launchctl bootout "gui/$(id -u)" "$extra" >/dev/null 2>&1 || true ;;
    esac
    rm -f "$extra" || fail "could not remove $extra"
done

# Per-app cache and temp folders under /var/folders (Metal shader cache and the like).
for darwin_dir in DARWIN_USER_CACHE_DIR DARWIN_USER_TEMP_DIR; do
    base="$(getconf "$darwin_dir" 2>/dev/null || true)"
    [ -n "$base" ] || continue
    rm -rf "${base%/}/$BUNDLE_ID" || fail "could not remove ${base%/}/$BUNDLE_ID"
done

for extra in "$HOME/Library/Preferences/ByHost/$BUNDLE_ID"*; do
    [ -e "$extra" ] || continue
    rm -f "$extra" || fail "could not remove $extra"
done
for extra in "$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/$BUNDLE_ID.sfl"*; do
    [ -e "$extra" ] || continue
    rm -f "$extra" || fail "could not remove $extra"
done

# The owner's optional log-upload token lives in the login Keychain, outside the
# container. Remove every copy so nothing of Dot stays behind.
if command -v security >/dev/null 2>&1; then
    while security delete-generic-password -s dot-github-token >/dev/null 2>&1; do :; done
    if security find-generic-password -s dot-github-token >/dev/null 2>&1; then
        fail "the Keychain item dot-github-token could not be removed"
    fi
fi

# TCC owns microphone, screen-recording and every other per-app approval.
if command -v tccutil >/dev/null 2>&1; then
    TCC_OUTPUT="$(tccutil reset All "$BUNDLE_ID" 2>&1)" || {
        case "$TCC_OUTPUT" in
            *"Failed to reset all approvals"*|*"No such"*|*"not found"*|*"No approvals"*)
                echo "note: macOS had no stored privacy approvals for $BUNDLE_ID"
                ;;
            *)
                fail "tccutil could not reset Dot's privacy approvals: $TCC_OUTPUT"
                ;;
        esac
    }
else
    fail "tccutil is unavailable; Dot's privacy approvals were not reset"
fi
# Audit S12: only crash reports that name Dot's bundle id, never another "Dot".
for report in "$HOME/Library/Logs/DiagnosticReports/Dot"*.ips; do
    [ -f "$report" ] || continue
    grep -qF "\"$BUNDLE_ID\"" "$report" 2>/dev/null || continue
    rm -f "$report" >/dev/null 2>&1 || true
done

# Remove ~/Applications only when this installer created it and it is empty.
if [ -f "$MARKER" ]; then
    rm -f "$MARKER" || fail "could not remove $MARKER"
    if rmdir "$INSTALL_DIR" 2>/dev/null; then
        echo "PASS: removed the ~/Applications folder the installer created"
    fi
fi

# Verify the important locations, not just the exit codes above. An app or a
# generic "Dot" folder left alone above is not Dot's and is not a leftover.
CHECK_PATHS=()
if [ "$APP_IS_DOT" = "1" ]; then
    CHECK_PATHS+=("$APP")
fi
LEFTOVERS=""
for path in \
    ${CHECK_PATHS[@]+"${CHECK_PATHS[@]}"} \
    ${REMOVED_DOT_FOLDERS[@]+"${REMOVED_DOT_FOLDERS[@]}"} \
    "$HOME/Library/Containers/$BUNDLE_ID" \
    "$HOME/Library/Group Containers/group.$BUNDLE_ID" \
    "$HOME/Library/Biome/sets/Default/App.Shortcut.Phrase/sourceIdentifier=$BUNDLE_ID" \
    "$HOME/Library/Caches/$BUNDLE_ID" \
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
    "$HOME/Library/Preferences/$BUNDLE_ID.plist"; do
    if [ -e "$path" ]; then
        LEFTOVERS="$LEFTOVERS $path"
    fi
done
if [ -n "$LEFTOVERS" ]; then
    fail "still present:$LEFTOVERS"
fi

echo "PASS: your Mac is back to how it was"
