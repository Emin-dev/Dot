#!/bin/bash
# BUILD-ONLY real Search vertical. Exit 77 means skipped, never passed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'SKIP: real Search vertical requires native Darwin arm64; no native evidence.' >&2
  exit 77
fi
if [[ $# != 2 ]]; then
  echo 'usage: verify_search_real_vertical_canary.sh <exact-historical-donor> <new-independent-work-directory>' >&2
  exit 2
fi
# No PYTHONPATH, proxy/CA, credentials, or generic launch overrides survive.
# Only nonsecret hosted-image labels are deliberately retained for provenance.
# The build-only toolchain is source-fixed, matching native CI, never inherited.
environment=(env -i PATH=/usr/bin:/bin LANG=en_US.UTF-8 PYTHONDONTWRITEBYTECODE=1
  DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer)
for name in ImageOS ImageVersion RUNNER_OS RUNNER_ARCH; do
  if [[ -n "${!name:-}" ]]; then environment+=("$name=${!name}"); fi
done
"${environment[@]}" /usr/bin/python3 -I -B "$ROOT/Tests/Fixtures/search_real_vertical_fixture.py" --preflight --donor "$1"
exec "${environment[@]}" /usr/bin/python3 -I -B "$ROOT/Tests/Fixtures/search_real_vertical_fixture.py" --run --donor "$1" --work "$2"
