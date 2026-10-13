#!/bin/bash
# Compile the real Whisper branch using an already verified official framework.
# No app execution, permissions, model loading or download.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DOT_WHISPER_FRAMEWORK:?Set the verified macOS whisper.framework path}"
test -f "$DOT_WHISPER_FRAMEWORK/Modules/module.modulemap"
OUT=$(mktemp -d "${TMPDIR:-/tmp}/dot-whisper-link.XXXXXX")
swiftc -O -warnings-as-errors -D DOT_COMPLETE_BUNDLE -target arm64-apple-macosx26.4 \
  -F "$(dirname "$DOT_WHISPER_FRAMEWORK")" -framework whisper \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$OUT/Dot" src/*.swift \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework CryptoKit
nm -u "$OUT/Dot" | grep _whisper_full >/dev/null
printf 'PASS: real Whisper C API compiled and linked at %s/Dot; no runtime was executed.\n' "$OUT"
