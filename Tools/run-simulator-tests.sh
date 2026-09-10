#!/bin/bash
# Runs the whole test suite on an iOS simulator, which is the only place the
# UIKit swizzles exist.
#
# `xcodebuild test` is the normal way to do this and is what you should use
# once Xcode's iOS platform matches its SDK. On a machine where it does not —
# xcodebuild then reports "iOS <version> is not installed" and offers no
# simulator destination at all — this script cross-compiles the test bundle
# with SwiftPM and runs it through the simulator's own xctest agent instead.
#
# Usage: Tools/run-simulator-tests.sh [simulator name] [XCTest filter]
set -euo pipefail

DEVICE="${1:-iPhone 17 Pro}"
FILTER="${2:-All}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PLATFORM="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
BUNDLE="$ROOT/.build/simulator-tests/FounderHQEventsPackageTests.xctest"

UDID="$(xcrun simctl list devices available -j \
  | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next(x['udid'] for v in d.values() for x in v if x['name']=='$DEVICE'))")"

swift build --build-tests --triple arm64-apple-ios15.0-simulator \
  -Xswiftc -sdk -Xswiftc "$SDK" -Xcc -isysroot -Xcc "$SDK"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
cp "$ROOT/.build/arm64-apple-ios-simulator/debug/FounderHQEventsPackageTests.xctest/Contents/MacOS/FounderHQEventsPackageTests" \
  "$BUNDLE/FounderHQEventsPackageTests"
cat > "$BUNDLE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>FounderHQEventsPackageTests</string>
  <key>CFBundleIdentifier</key><string>com.founderhq.events.PackageTests</string>
  <key>CFBundleName</key><string>FounderHQEventsPackageTests</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST

xcrun simctl boot "$UDID" 2>/dev/null || true
export SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$PLATFORM/Developer/Library/Frameworks"
export SIMCTL_CHILD_DYLD_LIBRARY_PATH="$PLATFORM/Developer/usr/lib"
exec xcrun simctl spawn "$UDID" \
  "$PLATFORM/Developer/Library/Xcode/Agents/xctest" -XCTest "$FILTER" "$BUNDLE"
