#!/bin/bash
# Builds dist/CoolMac.app from the SwiftPM package — no Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/CoolMac.app"
echo "Building release binaries..."
swift build -c release --product coolmac
swift build -c release --product coolmac-helper

echo "Generating icon..."
rm -rf /tmp/AppIcon.iconset dist/AppIcon.icns
swift scripts/make-icon.swift /tmp/AppIcon.iconset
mkdir -p dist
iconutil -c icns /tmp/AppIcon.iconset -o dist/AppIcon.icns

echo "Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/coolmac "$APP/Contents/MacOS/CoolMac"
cp .build/release/coolmac-helper "$APP/Contents/Resources/coolmac-helper"
cp LaunchDaemon/com.coolmac.helper.plist "$APP/Contents/Resources/com.coolmac.helper.plist"
cp App/install-helper.sh "$APP/Contents/Resources/install-helper.sh"
cp App/Info.plist "$APP/Contents/Info.plist"
cp dist/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/Resources/install-helper.sh"

echo "Ad-hoc signing (local use; notarization needs a Developer ID)..."
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" 2>&1 | tail -1
echo "Done: $APP"
echo "Run it with:  open $APP"
