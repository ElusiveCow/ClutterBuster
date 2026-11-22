#!/usr/bin/env bash
# Builds "build/Clutter Buster.app" from the Swift package.
# Pass --install to also install it into Applications and launch it (see scripts/install-app.sh).
# Run scripts/setup-signing.sh once first so permission grants survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGNING_IDENTITY="Clutter Buster Local Signing"
BUNDLE_ID="com.elusivecow.ClutterBuster"

swift build -c release --product ClutterBuster
BIN="$(swift build -c release --show-bin-path)/ClutterBuster"
APP="build/Clutter Buster.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClutterBuster"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign by hash so a duplicate certificate with the same name can't make codesign ambiguous.
IDENTITY_HASH="$(security find-identity -p codesigning 2>/dev/null \
    | awk -v name="\"$SIGNING_IDENTITY\"" 'index($0, name) { print $2; exit }')"
if [[ -n "$IDENTITY_HASH" ]]; then
    # A local certificate gets nothing from Apple's timestamp server, which only adds a ~20 s wait.
    codesign --force --timestamp=none --sign "$IDENTITY_HASH" --identifier "$BUNDLE_ID" "$APP"
else
    echo "warning: \"$SIGNING_IDENTITY\" not found; signing ad hoc." >&2
    echo "warning: macOS will ask for Desktop and Finder access again after every build." >&2
    echo "warning: run scripts/setup-signing.sh once to fix this." >&2
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    exec scripts/install-app.sh
fi
