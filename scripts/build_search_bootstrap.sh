#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'SKIP: Search native bootstrap requires the macOS SDK.' >&2
  exit 77
fi
if [[ $# != 1 ]]; then echo 'usage: build_search_bootstrap.sh <staged-Search-payload>' >&2; exit 2; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$1"
mkdir -p "$PAYLOAD/bin"
xcrun clang -arch arm64 -mmacosx-version-min=15.0 -std=c11 -Wall -Wextra -Werror -O2 \
  "$ROOT/packaging/search/dot-search-bootstrap.c" -o "$PAYLOAD/bin/dot-search-bootstrap" -lsandbox
printf '%s\n' 'Built unsigned Search bootstrap. Sign as app.dot.search-bootstrap during exact payload assembly; this does not grant runtime admission.'
