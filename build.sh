#!/bin/bash
# Build Dot.app + Dot.dmg — pure Swift/SwiftUI, no external deps.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Dot.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ compiling"
swiftc -O \
  -o "$APP/Contents/MacOS/Dot" \
  src/Models.swift src/Engine.swift src/Speech.swift src/ChatView.swift src/App.swift \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework Speech \
  -framework AudioToolbox

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp icon.png "$APP/Contents/Resources/Icon.png"

echo "▸ icon"
ICONSET=build/Icon.iconset
mkdir -p "$ICONSET"
sips -z 16 16     icon.png --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     icon.png --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     icon.png --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     icon.png --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   icon.png --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   icon.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   icon.png --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   icon.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   icon.png --out "$ICONSET/icon_512x512.png"    >/dev/null
sips -z 1024 1024 icon.png --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Icon.icns"
rm -rf "$ICONSET"

echo "▸ signing (ad-hoc)"
codesign --force --sign - "$APP"

echo "▸ dmg"
STAGE=build/stage
rm -rf "$STAGE" Dot.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Dot" -srcfolder "$STAGE" -ov -format UDZO -o Dot.dmg

echo "✅ done: $(pwd)/Dot.dmg ($(du -h Dot.dmg | cut -f1))"
