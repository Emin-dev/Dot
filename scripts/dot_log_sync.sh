#!/bin/bash
# dot_log_sync.sh — mirror one Dot's text logs to the dedicated logs branch.
#
# Usage:
#   GH_TOKEN=<fine-grained token: Contents read/write> bash scripts/dot_log_sync.sh
#
# Layout: dot/<stable-install-id>/<launch-timestamp-UTC>/
# The token is used in-memory only and never written to the repository. The app's
# own uploader (DotLogSync) is preferred; this script is the manual fallback.
set -euo pipefail

: "${DOT_LOGS_REPO:=https://github.com/Emin-dev/Dot.git}"
: "${DOT_LOGS_BRANCH:=dot-logs}"
: "${GH_TOKEN:?set GH_TOKEN (fine-grained token with Contents: read and write)}"

SUPPORT="${HOME}/Library/Application Support/Dot"
INSTALL_FILE="$SUPPORT/install-id"
mkdir -p "$SUPPORT"
if [ -s "$INSTALL_FILE" ]; then
    INSTALL_ID=$(tr 'A-Z' 'a-z' < "$INSTALL_FILE" | tr -cd 'a-z0-9' | cut -c1-32)
fi
if [ -z "${INSTALL_ID:-}" ] || [ "${#INSTALL_ID}" -lt 8 ]; then
    INSTALL_ID=$(uuidgen | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-16)
    printf '%s\n' "$INSTALL_ID" > "$INSTALL_FILE"
    chmod 600 "$INSTALL_FILE"
fi
LAUNCH=$(date -u +%Y-%m-%dT%H-%M-%SZ)
DEST="dot/$INSTALL_ID/$LAUNCH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dot-sync.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK"
cd "$WORK"
git config --global user.name  "dot-$INSTALL_ID"
git config --global user.email "dot-$INSTALL_ID@users.noreply.github.com"
export GH_TOKEN
# Single quotes keep the literal variable in the throwaway config; the token is
# expanded from the inherited environment in memory, never written to disk/argv.
git config --global credential.helper '!f() { echo username=x-access-token; echo password="$GH_TOKEN"; }; f'

if git ls-remote --exit-code --heads "$DOT_LOGS_REPO" "$DOT_LOGS_BRANCH" >/dev/null 2>&1; then
    git clone --depth 1 --branch "$DOT_LOGS_BRANCH" "$DOT_LOGS_REPO" repo
else
    git clone --depth 1 "$DOT_LOGS_REPO" repo
    cd repo
    git checkout -b "$DOT_LOGS_BRANCH"
    cd ..
fi

mkdir -p "repo/$DEST"
# Same last-line secret masking as the in-app uploader: never publish a token,
# password or API key even when an older build wrote it into a log file.
sanitize() {
    perl -pe '
        s/((?:Authorization)\s*[:=]\s*Bearer\s+)\S+/${1}[REDACTED]/gi;
        s/\bgh[pousr]_[A-Za-z0-9]{20,}\b/[REDACTED_TOKEN]/g;
        s/\bgithub_pat_[A-Za-z0-9_]{20,}\b/[REDACTED_TOKEN]/g;
        s/\b(password|passwd|passphrase|secret)\s*[:=]\s*[^\r\n]+/${1}=[REDACTED]/gi;
        s/\b(password|passwd|passphrase|secret)\s+(?:is|was)\s+[^\r\n]+/${1}=[REDACTED]/gi;
        s/\b(token|api(?:[\s_-]?key))\s*[:=]\s*\S+/${1}=[REDACTED]/gi;
        s/\b(token|api(?:[\s_-]?key))\s+(?:is|was)\s+\S+/${1}=[REDACTED]/gi;
    ' "$1"
}
for name in dot_chat_log.txt dot_chat_log.1.txt; do
    if [ -f "$SUPPORT/Logs/$name" ]; then
        sanitize "$SUPPORT/Logs/$name" > "repo/$DEST/$name"
    fi
done
if [ -f "$SUPPORT/dot-health.json" ]; then
    sanitize "$SUPPORT/dot-health.json" > "repo/$DEST/dot-health.json"
fi
cat > "repo/$DEST/meta.json" <<JSON
{"schema_version":1,"install_id":"$INSTALL_ID","launch_timestamp_utc":"$LAUNCH","manual_sync":true}
JSON

cd repo
if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "logs: $INSTALL_ID $LAUNCH"
    git push origin "HEAD:$DOT_LOGS_BRANCH"
    unset GH_TOKEN
    echo "pushed $DEST to $DOT_LOGS_REPO ($DOT_LOGS_BRANCH)"
else
    echo "nothing new for $DEST"
fi
