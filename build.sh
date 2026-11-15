#!/bin/bash
# Builds Keyla.app (release) next to this script. Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=Keyla.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Keyla "$APP/Contents/MacOS/Keyla"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Keyla</string>
  <key>CFBundleDisplayName</key><string>Keyla</string>
  <key>CFBundleIdentifier</key><string>app.keyla.Keyla</string>
  <key>CFBundleExecutable</key><string>Keyla</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Keyla записывает голос только пока вы диктуете.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Keyla превращает вашу речь в текст.</string>
</dict></plist>
PLIST
# Stable local identity keeps macOS privacy permissions across rebuilds; falls back to ad-hoc.
ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"Keyla Local Signing"/{print $2; exit}')
codesign --force --deep --sign "${ID:--}" "$APP"
echo "Built $(pwd)/$APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Keyla || true
  rm -rf /Applications/Keyla.app && cp -R "$APP" /Applications/
  open /Applications/Keyla.app
  echo "Installed to /Applications"
fi
