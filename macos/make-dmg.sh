#!/bin/zsh
# Builds Pixelpress.app, then packages it as dist/Pixelpress.dmg with an Applications shortcut.
set -euo pipefail
cd "${0:A:h}"
./build.sh
STAGE=$(mktemp -d)
cp -R dist/Pixelpress.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f dist/Pixelpress.dmg
hdiutil create -volname "Pixelpress" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov dist/Pixelpress.dmg >/dev/null
rm -rf "$STAGE"
echo "Built dist/Pixelpress.dmg"
