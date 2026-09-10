#!/bin/bash
# Builds Tools/InteractionHostApp for the iOS simulator, installs it, and runs
# it. It exists because the XCTest bundle has no `UIApplication`, so the
# `UIApplication.sendAction` hook cannot be exercised from a unit test.
#
# Usage: Tools/run-interaction-host-app.sh [simulator name]
set -euo pipefail

DEVICE="${1:-iPhone 17 Pro}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
BUILD="$ROOT/.build/interaction-host-app"
APP="$BUILD/FounderHQInteractionHost.app"
BUNDLE_ID="com.founderhq.events.interactionhost"

UDID="$(xcrun simctl list devices available -j \
  | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next(x['udid'] for v in d.values() for x in v if x['name']=='$DEVICE'))")"

rm -rf "$APP"
mkdir -p "$APP"
swiftc -sdk "$SDK" -target arm64-apple-ios15.0-simulator \
  -o "$APP/FounderHQInteractionHost" \
  "$ROOT"/Sources/FounderHQEvents/*.swift \
  "$ROOT"/Tools/InteractionHostApp/main.swift

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>FounderHQInteractionHost</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>FounderHQInteractionHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UILaunchScreen</key><dict/>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string></array>
</dict>
</plist>
PLIST

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE_ID"
