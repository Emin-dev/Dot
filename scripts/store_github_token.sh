#!/bin/bash
# Store a GitHub token with release permission in the macOS Keychain so the
# publisher does not need a device login. The token is never printed or written
# to the repository.
#
# Create a classic PAT with the `repo` scope (or a fine-grained token with
# Contents: Read and write on Emin-dev/Dot), then run:
#   bash scripts/store_github_token.sh
set -euo pipefail
SERVICE="dot-github-token"
read -rsp "Paste GitHub token (input hidden): " TOKEN
echo
[ -n "$TOKEN" ] || { echo "No token entered." >&2; exit 1; }
user=$(curl -fsS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  https://api.github.com/user | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("login",""))') || {
    echo "Token rejected by GitHub." >&2; exit 1; }
[ -n "$user" ] || { echo "Token rejected by GitHub." >&2; exit 1; }
security add-generic-password -a "$USER" -s "$SERVICE" -w "$TOKEN" -U
echo "Stored release token for $user in Keychain service '$SERVICE'."
