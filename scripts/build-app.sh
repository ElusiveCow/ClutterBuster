#!/usr/bin/env bash
# Builds "build/Clutter Buster.app" from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product ClutterBuster
BIN="$(swift build -c release --show-bin-path)/ClutterBuster"
APP="build/Clutter Buster.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClutterBuster"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"
