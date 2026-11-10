#!/bin/sh
# Builds "iPhone Rig.app" (viewer + capture) into ./build.
# Needs only the Command Line Tools (swiftc), not Xcode.
set -e
cd "$(dirname "$0")/.."
APP="build/iPhone Rig.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" bin
swiftc -O -swift-version 5 capture/iphone-capture.swift -o "$APP/Contents/MacOS/iphone-rig"
cp "$APP/Contents/MacOS/iphone-rig" bin/iphone-capture
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>iPhone Rig</string>
  <key>CFBundleDisplayName</key><string>iPhone Rig</string>
  <key>CFBundleIdentifier</key><string>local.iphone-rig.viewer</string>
  <key>CFBundleExecutable</key><string>iphone-rig</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>iPhone Rig reads your iPhone's screen over the USB cable so you and Claude can see it.</string>
  <key>NSMicrophoneUsageDescription</key><string>The iPhone screen feed includes an audio track; iPhone Rig does not record it.</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "built $APP"
