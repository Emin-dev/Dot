#!/bin/sh
set -e
ICONSET="${PROJECT_DIR}/build/Icon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "${PROJECT_DIR}/icon.png" --out "$ICONSET/icon_${s}x${s}.png" > /dev/null
  d=$((s * 2))
  sips -z $d $d "${PROJECT_DIR}/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null
done
sips -z 1024 1024 "${PROJECT_DIR}/icon.png" --out "$ICONSET/icon_512x512@2x.png" > /dev/null
iconutil -c icns "$ICONSET" -o "${PROJECT_DIR}/Resources/Icon.icns"

