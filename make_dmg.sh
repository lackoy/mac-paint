#!/bin/zsh
# Builds Paint.app and packages it as build/Paint.dmg (drag-to-Applications installer).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

STAGE=build/dmg
rm -rf "$STAGE" build/Paint.dmg
mkdir -p "$STAGE"
cp -R build/Paint.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "그림판" -srcfolder "$STAGE" -ov -format UDZO build/Paint.dmg >/dev/null
rm -rf "$STAGE"
echo "Built build/Paint.dmg"
