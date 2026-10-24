#!/bin/bash
# Store a GitHub token with release permission in the macOS Keychain so the
# publisher does not need a device login. The token is never printed or written
# to the repository, and it never appears on a command line (visible to `ps`).
#
# Create a classic PAT with the `repo` scope (or a fine-grained token with
# Contents: Read and write on Emin-dev/Dot), then run:
#   bash scripts/store_github_token.sh
set -euo pipefail
SERVICE="dot-github-token"
echo "security asks for the GitHub token twice (input hidden); paste it both times."
# -w is the last argument and has no value, so `security` prompts for the token
# itself instead of taking it from argv.
security add-generic-password -a "$USER" -s "$SERVICE" -U -w
# Read it back through a pipe, never argv, to check it with GitHub.
forget() {
    security delete-generic-password -a "$USER" -s "$SERVICE" >/dev/null 2>&1 || true
    echo "$1 It was removed from Keychain service '$SERVICE'; run this script again." >&2
    exit 1
}
TOKEN="$(security find-generic-password -a "$USER" -s "$SERVICE" -w 2>/dev/null || true)"
[ -n "$TOKEN" ] || forget "No token entered."
# Pass the header through a config pipe, never argv, so the token is not visible
# to `ps` while the verification request runs.
user=$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\n' "$TOKEN" \
  | curl -fsS --config - https://api.github.com/user \
  | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("login",""))') \
  || forget "GitHub did not accept the token (or could not be reached)."
unset TOKEN
[ -n "$user" ] || forget "GitHub did not accept the token."
echo "Stored release token for $user in Keychain service '$SERVICE'."
