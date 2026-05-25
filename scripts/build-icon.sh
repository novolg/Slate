#!/usr/bin/env bash
# Generate Slate.icns from assets/icon-source.png.
# Usage: scripts/build-icon.sh
# Output: build/Slate.icns

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJECT_ROOT/assets/icon-source.png"
ICONSET="$PROJECT_ROOT/build/Slate.iconset"
OUT="$PROJECT_ROOT/build/Slate.icns"

if [[ ! -f "$SRC" ]]; then
    echo "✗ source icon not found at $SRC" >&2
    exit 1
fi

mkdir -p "$PROJECT_ROOT/build"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Standard macOS iconset sizes. Names matter for `iconutil`.
declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
    px="${entry%%:*}"
    name="${entry#*:}"
    sips -z "$px" "$px" "$SRC" --out "$ICONSET/$name" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"
echo "✓ built $OUT"
