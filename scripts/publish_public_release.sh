#!/bin/bash
# Publish the runtime-only public package to a GitHub release.
#
# Prerequisite: build-public/Dot.zip (run scripts/package_public_release.sh) and a
# token with repo release permission in GITHUB_TOKEN (or GH_TOKEN).
#
# The asset is named Dot.zip so README's one-line installer resolves:
#   https://github.com/Emin-dev/Dot/releases/latest/download/Dot.zip
set -euo pipefail
cd "$(dirname "$0")/.."

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
[ -n "$TOKEN" ] || { echo "publish_public_release: set GITHUB_TOKEN or GH_TOKEN" >&2; exit 1; }
ZIP="build-public/Dot.zip"
SUM="$ZIP.sha256"
[ -f "$ZIP" ] || { echo "publish_public_release: run scripts/package_public_release.sh first" >&2; exit 1; }
TAG="${1:-public-$(git rev-parse --short HEAD)}"
COMMIT="$(git rev-parse HEAD)"

body=$(cat <<JSON
{"tag_name":"$TAG","target_commitish":"$COMMIT","name":"Dot $TAG",
 "body":"Runtime-only Dot app. On first launch it downloads the exact signed-manifest Qwen3.8-27B model from Hugging Face and verifies every SHA-256. Apple Development signed; not notarised yet. Run scripts/package_public_release.sh to reproduce the asset.",
 "draft":false,"prerelease":true}
JSON
)
release=$(curl -fsS -X POST \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  -d "$body" https://api.github.com/repos/Emin-dev/Dot/releases)
id=$(/usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' <<<"$release")
echo "release $TAG id=$id"

for pair in "$ZIP:Dot.zip:application/zip" "$SUM:Dot.zip.sha256:text/plain"; do
  file="${pair%%:*}"; rest="${pair#*:}"; name="${rest%%:*}"; type="${rest#*:}"
  echo "uploading $file as $name"
  curl -fsS -X POST \
    -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    -H "Content-Type: $type" --data-binary @"$file" \
    "https://uploads.github.com/repos/Emin-dev/Dot/releases/$id/assets?name=$name" >/dev/null
done
echo "PASS: https://github.com/Emin-dev/Dot/releases/tag/$TAG"
