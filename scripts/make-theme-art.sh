#!/usr/bin/env bash
# Rebuilds Resources/Themes/*.png from generated illustrations on flat backgrounds.
#   scripts/make-theme-art.sh <folder with *_raw.png>
# Each raw image is named <art>_raw.png (for example fall_corner_raw.png) and cut out
# with scripts/cutout.swift using the background color it was generated on.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:?usage: make-theme-art.sh <folder with *_raw.png>}"
OUT="Resources/Themes"
mkdir -p "$OUT"

# name  background  extra flags
ART=(
    "fall_corner white --holes"
    "fall_leaf white --holes --max 128"
    "winter_corner magenta --despill-all"
    "spring_corner white --holes"
    "ocean_corner white --holes"
    "retro_corner white --holes"
    "halloween_corner white --holes"
    "christmas_corner white --holes"
    "cafe_corner white --flood"
    "space_corner green"
    "jungle_corner white --holes"
    "library_corner white --holes"
    "beach_corner green"
    "zen_corner white --holes"
    "arcade_corner white --holes"
    "catnap_corner green"
)

for entry in "${ART[@]}"; do
    read -r name bg extra <<<"$entry"
    raw="$SRC/${name}_raw.png"
    if [[ ! -f "$raw" ]]; then
        echo "skip $name (no $raw)"
        continue
    fi
    # shellcheck disable=SC2086
    swift scripts/cutout.swift "$raw" "$OUT/$name.png" --bg "$bg" $extra
done
