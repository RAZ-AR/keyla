#!/bin/bash
# Builds Keyla.app and packs it into dist/Keyla-<version>.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION=$(plutil -extract CFBundleShortVersionString raw Keyla.app/Contents/Info.plist)
STAGE=$(mktemp -d)
cp -R Keyla.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
DMG="dist/Keyla-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Keyla" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"Keyla Local Signing"/{print $2; exit}')
[ -n "$ID" ] && codesign --force --sign "$ID" "$DMG"
shasum -a 256 "$DMG"
echo "Built $DMG"
