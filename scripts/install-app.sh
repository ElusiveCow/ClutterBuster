#!/usr/bin/env bash
# Moves "build/Clutter Buster.app" into /Applications (or ~/Applications if that isn't
# writable), registers it with LaunchServices, and launches the installed copy.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Clutter Buster.app"
BUNDLE_ID="com.elusivecow.ClutterBuster"
SRC="build/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d "$SRC" ]]; then
    echo "error: $SRC not found; run scripts/build-app.sh first." >&2
    exit 1
fi

if [[ -w /Applications ]]; then
    DEST_DIR="/Applications"
    OTHER_DIR="$HOME/Applications"
else
    DEST_DIR="$HOME/Applications"
    OTHER_DIR="/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/$APP_NAME"

# Quit gracefully so the app puts the desktop icons back, then force it only if it hangs.
if pgrep -x ClutterBuster >/dev/null; then
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    for _ in {1..50}; do
        pgrep -x ClutterBuster >/dev/null || break
        sleep 0.2
    done
    if pgrep -x ClutterBuster >/dev/null; then
        echo "warning: Clutter Buster didn't quit; killing it." >&2
        pkill -x ClutterBuster || true
        sleep 0.5
    fi
fi

# Remove a copy left in the other Applications folder so Apps only lists one.
OTHER="$OTHER_DIR/$APP_NAME"
if [[ -d "$OTHER" && -w "$OTHER_DIR" ]] \
    && [[ "$(defaults read "$OTHER/Contents/Info" CFBundleIdentifier 2>/dev/null)" == "$BUNDLE_ID" ]]; then
    "$LSREGISTER" -u "$OTHER" >/dev/null 2>&1 || true
    rm -rf "$OTHER"
fi

# Move rather than copy: Spotlight re-indexes any bundle left in build/, which would show a
# second Clutter Buster in Apps and Spotlight.
"$LSREGISTER" -u "$SRC" >/dev/null 2>&1 || true
rm -rf "$DEST"
ditto "$SRC" "$DEST"
rm -rf "$SRC"

"$LSREGISTER" -f "$DEST"

echo "Installed $DEST"
open "$DEST"
