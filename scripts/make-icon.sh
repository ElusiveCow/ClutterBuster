#!/usr/bin/env bash
# Regenerates Resources/AppIcon-1024.png and Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

swift scripts/make-icon.swift Resources/AppIcon-1024.png

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$ICONSET"

echo "Wrote Resources/AppIcon-1024.png and Resources/AppIcon.icns"
