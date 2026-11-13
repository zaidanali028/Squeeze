#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Squeeze.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos13.0"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling Squeeze.app…"
swiftc -O -swift-version 5 -target "$TARGET" -sdk "$SDK" -parse-as-library \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Sources/Engine.swift" \
  "$ROOT/Sources/JobModel.swift" \
  "$ROOT/Sources/ContentView.swift" \
  "$ROOT/Sources/SqueezeApp.swift" \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  -framework UserNotifications \
  -o "$APP/Contents/MacOS/Squeeze"

echo "Compiling squeeze-cli…"
swiftc -O -swift-version 5 -target "$TARGET" -sdk "$SDK" -parse-as-library \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Sources/Engine.swift" \
  "$ROOT/Sources/CLI.swift" \
  -framework AppKit \
  -o "$APP/Contents/MacOS/squeeze-cli"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "Built: $APP"
echo "CLI:   $APP/Contents/MacOS/squeeze-cli"
