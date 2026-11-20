#!/bin/zsh
# Builds Pixelpress.app (universal) in ./dist
set -euo pipefail
cd "${0:A:h}"
swift build -c release --arch arm64 --arch x86_64
BIN=.build/apple/Products/Release/Pixelpress
APP=dist/Pixelpress.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pixelpress"
cp Support/Info.plist "$APP/Contents/Info.plist"
ICON_TMP=$(mktemp -d)
swift Support/make-icon.swift "$ICON_TMP/AppIcon.png"
"$BIN" convert -f icns -o "$ICON_TMP" "$ICON_TMP/AppIcon.png" >/dev/null   # Pixelpress makes its own icon
cp "$ICON_TMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"
codesign --force --sign - "$APP"
echo "Built $APP"
