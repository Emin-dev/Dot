#!/bin/bash
# dot_log_sync.sh — mirror one Dot's logs and health to its own folder on GitHub,
# so every Dot in the world publishes what it did, what failed, and what it could
# not do, and an external agent (or another Dot) can read and improve on it.
#
# Usage:
#   DOT_LOGS_REPO=https://github.com/<owner>/<repo>.git \
#   DOT_ID=<unique-name-for-this-dot> \
#   GH_TOKEN=<fine-grained-or-classic-pat> \
#   bash scripts/dot_log_sync.sh
#
# The token is used in-memory only (git credential helper env); it is never written
# to disk, never committed, and never bundled with the app.
set -euo pipefail

: "${DOT_LOGS_REPO:?set DOT_LOGS_REPO (e.g. https://github.com/owner/dot-logs.git)}"
: "${DOT_ID:?set DOT_ID (unique name for this Dot, e.g. emin-mac-m5)}"
: "${GH_TOKEN:?set GH_TOKEN (personal access token with contents:write on that repo)}"

SUPPORT="${HOME}/Library/Application Support/Dot"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dot-sync.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The token goes through an in-memory git config in a throwaway HOME, so it never
# touches the shell history or a persistent config file.
export HOME="$WORK"
git config --global user.name  "$DOT_ID"
git config --global user.email "$DOT_ID@dot.local"
git config --global credential.helper "!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f"

git clone --depth 1 "$DOT_LOGS_REPO" repo
mkdir -p "repo/dots/$DOT_ID"
# Logs (rotated, text) and the machine-readable health snapshot travel together.
[ -d "$SUPPORT/Logs" ] && cp -R "$SUPPORT/Logs/." "repo/dots/$DOT_ID/logs/"
[ -f "$SUPPORT/dot-health.json" ] && cp "$SUPPORT/dot-health.json" "repo/dots/$DOT_ID/"
[ -f "$SUPPORT/Records/dot_records.sqlite" ] && cp "$SUPPORT/Records/dot_records.sqlite" "repo/dots/$DOT_ID/" || true

cd repo
# Only push when there is something new; a silent no-op is the steady state.
if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "$DOT_ID: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    git push origin HEAD:main 2>/dev/null || git push origin HEAD:master
    echo "pushed $DOT_ID logs to $DOT_LOGS_REPO (dots/$DOT_ID)"
else
    echo "nothing new for $DOT_ID"
fi
