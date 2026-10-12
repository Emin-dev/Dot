#!/bin/bash
# Bounded, model-free build gates shared by branch CI and release packaging.
set -euo pipefail
cd "$(dirname "$0")/.."
LOGS=$(mktemp -d "${TMPDIR:-/tmp}/dot-checks.XXXXXX")
# Test-only interpreter, explicitly selected before XCTest; never a product runtime fallback.
TEST_PYTHON=$(python3 -B -c 'import sys,ssl; assert sys.version_info >= (3,11), "Tests require Python3.11+"; assert ssl.OPENSSL_VERSION.startswith("OpenSSL ") and ssl.OPENSSL_VERSION_INFO >= (1,1,1), "Tests require supported OpenSSL"; print(sys.executable)')
"$TEST_PYTHON" -B -c 'import sys,ssl; print("Test Python:",sys.version); print("Test TLS:",ssl.OPENSSL_VERSION)'
python3 -B -m unittest discover -s Tests/Python -v 2>&1 | tee "$LOGS/python.log"
python3 -B scripts/test_voice_sandbox.py 2>&1 | tee "$LOGS/sandbox.log"
python3 -B scripts/test_splash_sandbox.py 2>&1 | tee "$LOGS/splash-sandbox.log"
python3 -B scripts/check_contracts.py
swift test 2>&1 | tee "$LOGS/swift.log"
xcodebuild -project Dot.xcodeproj -scheme Dot -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$LOGS/Debug" \
  DOT_TEST_PYTHON="$TEST_PYTHON" CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$LOGS/test.log"
xcodebuild -project Dot.xcodeproj -scheme Dot -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$LOGS/Release" \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$LOGS/release.log"
bash build.sh 2>&1 | tee "$LOGS/package.log"
if grep -Ei '(^|[[:space:]])warning:|xcodebuild: WARNING:' "$LOGS"/*.log; then
  echo 'FAIL: warning detected in verification or delivered-app build'; exit 1
fi
codesign --verify --strict build/Dot.app
file build/Dot.app/Contents/MacOS/Dot
python3 -B - <<'PY'
import json, pathlib, subprocess
resources = pathlib.Path('build/Dot.app/Contents/Resources')
assert (resources/'Voice/bionic_helper.py').is_file()
assert (resources/'Voice/BIONIC-LICENSE.txt').is_file()
provenance = json.loads((resources/'build-provenance.json').read_text())
assert provenance['commit'] == subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
print('PASS: bundle helper, license and exact source revision verified')
PY
echo 'PASS: all build/test/package logs contain zero warning diagnostics'
