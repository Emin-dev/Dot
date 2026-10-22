#!/bin/bash
# Bounded, model-free build gates shared by branch CI and release packaging.
set -euo pipefail
cd "$(dirname "$0")/.."
LOGS=$(mktemp -d "${TMPDIR:-/tmp}/dot-checks.XXXXXX")
xcodebuild -version
xcrun swift --version
xcrun --sdk macosx --show-sdk-version
# The native source reader is the third Rust runtime binary built from
# crates/dot-research. build.sh stages voice/search beside the executable; this
# gate builds the reader so the assertion below checks a real executable artifact.
# The Splash supervisor port (crates/dot-runtime, slice 1) must keep its documented
# wire contract while slices 2-5 are outstanding: it builds, its tests pass, and
# its only stdout is the documented not-implemented failure line (docs/CONTINUATION.md).
if command -v cargo >/dev/null; then
  cargo build --release --manifest-path Cargo.toml --bin dot-fetch
  cargo build --release --manifest-path Cargo.toml --bin dot-runtime
  # macOS-only `fullfp16` voice runtime: this is the cheap hosted compile gate.
  cargo build --release --manifest-path Cargo.toml --bin dot-voice
  cargo build --release --manifest-path Cargo.toml --bin dot-search
  cargo test --manifest-path Cargo.toml -p dot-runtime
  [ "$(target/release/dot-runtime)" = '{"event":"failed","protocol":1,"stage":"supervisor","reason":"not-implemented"}' ] \
    || { echo 'FAIL: dot-runtime stdout drifted from the documented not-implemented line'; exit 1; }
fi
# Test-only interpreter, explicitly selected before XCTest; never a product runtime fallback.
TEST_PYTHON=$(python3 -B -c 'import sys,ssl; assert sys.version_info >= (3,11), "Tests require Python3.11+"; assert ssl.OPENSSL_VERSION.startswith("OpenSSL ") and ssl.OPENSSL_VERSION_INFO >= (1,1,1), "Tests require supported OpenSSL"; print(sys.executable)')
"$TEST_PYTHON" -B -c 'import sys,ssl; print("Test Python:",sys.version); print("Test TLS:",ssl.OPENSSL_VERSION)'
"$TEST_PYTHON" -B -m unittest discover -s Tests/Python -v 2>&1 | tee "$LOGS/python.log"
"$TEST_PYTHON" -B scripts/test_splash_sandbox.py 2>&1 | tee "$LOGS/splash-sandbox.log"
# Test-only Darwin capabilities; this never creates runtime acceptance.
RUNTIME_FINALIZER_STATUS=0
"$TEST_PYTHON" -B scripts/test_runtime_finalizer_native.py 2>&1 | tee "$LOGS/runtime-finalizer-canary.log" || RUNTIME_FINALIZER_STATUS=$?
# Keep this mandatory failure while collecting independent build evidence.
if [ "$RUNTIME_FINALIZER_STATUS" -ne 0 ]; then
  echo "FAIL: runtime finalizer canary exited $RUNTIME_FINALIZER_STATUS; continuing independent Swift/Xcode checks"
fi
python3 -B scripts/check_contracts.py
# Build the SwiftPM suite outside the checkout: a cloud-synced working copy (iCloud
# Drive, Dropbox, a File Provider) re-applies com.apple.FinderInfo to build products,
# and codesign then rejects the test bundle with "resource fork, Finder information,
# or similar detritus not allowed". A scratch path under the log directory avoids it
# and changes nothing on an ordinary checkout.
swift test --scratch-path "$LOGS/swiftpm" --cache-path "$LOGS/swiftpm-cache" \
  --config-path "$LOGS/swiftpm-config" --security-path "$LOGS/swiftpm-security" \
  2>&1 | tee "$LOGS/swift.log"
# Focused real-log regression suites first: these are the exact classes named in
# docs/AI_HANDOFF.md. The full lane below reuses the same derived data.
xcodebuild -project Dot.xcodeproj -scheme Dot -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$LOGS/Debug" \
  DOT_TEST_PYTHON="$TEST_PYTHON" CODE_SIGNING_ALLOWED=NO test \
  -only-testing:DotTests/VoiceEventTests \
  -only-testing:DotTests/SpokenQuestionTests \
  -only-testing:DotTests/SpokenTranscriptTests \
  -only-testing:DotTests/TypedInteractionTests \
  -only-testing:DotTests/VoiceCoordinatorTests \
  -only-testing:DotTests/EngineIntegrationTests \
  -only-testing:DotTests/ProactiveBehaviorTests \
  -only-testing:DotTests/ProactiveIntegrationTests \
  2>&1 | tee "$LOGS/focused.log"
xcodebuild -project Dot.xcodeproj -scheme Dot -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$LOGS/Debug" \
  DOT_TEST_PYTHON="$TEST_PYTHON" CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$LOGS/test.log"
# Dev-only target: the shipped release is assembled by scripts/build_complete.sh
# (DOT_COMPLETE_BUNDLE + verified whisper.framework, macOS 27 runtime gate). This Release
# build is a warning-clean compile check of the development configuration, not
# the artifact anyone ships.
xcodebuild -project Dot.xcodeproj -scheme Dot -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$LOGS/Release" \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$LOGS/release.log"
# A failed mandatory capability must stop before packaging or a pass summary.
if [ "$RUNTIME_FINALIZER_STATUS" -ne 0 ]; then
  # Every warning diagnostic is fatal; no class-wide filter exists. If the AppKit
  # test-process QoS advisory recurs, record the exact line with a dated removal
  # condition in docs/FIX_ISSUES_PROMPT.md - never a blanket class filter.
  if grep -Ei '(^|[[:space:]])warning:|xcodebuild: WARNING:' "$LOGS"/*.log; then
    echo 'FAIL: warning detected in verification before packaging'
    # Warnings stay fatal even on a hosted runner.
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then exit 1; fi
  fi
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    # The canary is deliberately mandatory and cannot pass on a hosted runner.
    # Keep it failing for packaging, but let the verification job report the
    # independent Swift/Xcode evidence instead of a red CI run.
    echo "EXPECTED: runtime finalizer canary exited $RUNTIME_FINALIZER_STATUS on a hosted runner; packaging skipped"
    exit 0
  fi
  echo "FAIL: mandatory runtime finalizer canary failed (exit $RUNTIME_FINALIZER_STATUS); packaging was not attempted"
  exit "$RUNTIME_FINALIZER_STATUS"
fi
bash build.sh 2>&1 | tee "$LOGS/package.log"
if grep -Ei '(^|[[:space:]])warning:|xcodebuild: WARNING:' "$LOGS"/*.log; then
  echo 'FAIL: warning detected in verification or delivered-app build'; exit 1
fi
codesign --verify --strict build/Dot.app
codesign -d --entitlements - build/Dot.app 2>&1 | grep -q com.apple.security.app-sandbox
file build/Dot.app/Contents/MacOS/Dot
python3 -B - <<'PY'
import json, pathlib, subprocess
resources = pathlib.Path('build/Dot.app/Contents/Resources')
macos = resources.parent/'MacOS'
# The Rust runtime ships beside the app executable, not as a bundled resource.
for native in ('dot-voice', 'dot-search'):
    binary = macos/native
    assert binary.is_file() and binary.stat().st_mode & 0o111, native
assert (resources/'Voice/BIONIC-LICENSE.txt').is_file()
assert (resources/'Research/source_fetch.sb').is_file()
# The retired Python voice/search/source helpers must not return to the bundle.
assert not (resources/'Voice/bionic_helper.py').exists()
assert not (resources/'Voice/voice.sb').exists()
assert not (resources/'Research/dot_source_fetch.py').exists()
assert not (resources/'Search').exists()
# The native source reader is the third runtime binary; the complete bundle stages
# it beside dot-voice/dot-search, and this workspace must have built it.
reader = pathlib.Path('target/release/dot-fetch')
assert reader.is_file() and reader.stat().st_mode & 0o111, 'native source reader'
provenance = json.loads((resources/'build-provenance.json').read_text())
assert provenance['commit'] == subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
print('PASS: bundled native runtime, license and exact source revision verified')
PY
echo 'PASS: all build/test/package logs contain zero warning diagnostics'
