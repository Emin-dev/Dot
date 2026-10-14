#!/bin/bash
# Additive build-only companion to verify_search_native_fixture.sh. It does not
# replace that full-runtime fixture or manufacture its production evidence.
set -euo pipefail
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'SKIP: pinned proxy fixture requires macOS arm64; no native execution performed.' >&2
  exit 77
fi
if [[ $# != 4 ]]; then
  echo 'usage: verify_search_proxy_native_fixture.sh <unaccepted-Search-payload> <expected-assembly-receipt-sha256> <exact-source-lock.json> <new-report.json>' >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PAYLOAD="$(cd "$1" && pwd -P)"
[[ -f "$PAYLOAD/python/bin/python3" && ! -L "$PAYLOAD/python/bin/python3" ]] || { echo 'Independent payload interpreter required.' >&2; exit 2; }
[[ ! -e "$4" ]] || { echo 'Refusing to overwrite an existing report.' >&2; exit 2; }
# Verify bytes with the OS hash-only controller before starting any payload code.
# This system Python is never used as a substitute Search runtime.
/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I -S -B -c '
import pathlib,sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "scripts"))
from search_proxy_canary_support import verify_payload,verify_source_lock
_, identity = verify_payload(pathlib.Path(sys.argv[2]), sys.argv[3])
verify_source_lock(sys.argv[4], identity["assembly_lock_sha256"])
' "$ROOT" "$PAYLOAD" "$2" "$3"
# Positive-list environment. Python isolation prevents PYTHON* startup hooks;
# env -i also strips libcurl proxy/NO_PROXY/CA and dynamic-loader variables.
exec /usr/bin/env -i PATH=/usr/bin:/bin HOME=/var/empty TMPDIR=/private/tmp LANG=en_US.UTF-8 \
  "$PAYLOAD/python/bin/python3" -I -S -B \
  "$ROOT/Tests/Fixtures/search_proxy_transport_fixture.py" --payload "$PAYLOAD" \
  --expected-receipt-sha256 "$2" --lock "$3" --report "$4"
