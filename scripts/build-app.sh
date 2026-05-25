#!/usr/bin/env bash
# Build Slate.app bundle from SPM build output.
# Usage: scripts/build-app.sh [debug|release]   (default: release)

set -euo pipefail

CONFIG="${1:-release}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Slate"
APP_BUNDLE="$PROJECT_ROOT/build/$APP_NAME.app"

cd "$PROJECT_ROOT"

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
EXEC="$BIN_PATH/$APP_NAME"

if [[ ! -x "$EXEC" ]]; then
    echo "✗ executable not found at $EXEC" >&2
    exit 1
fi

echo "→ assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXEC" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_ROOT/scripts/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Build (or reuse) the .icns and embed it.
ICON_OUT="$PROJECT_ROOT/build/Slate.icns"
if [[ -f "$PROJECT_ROOT/assets/icon-source.png" ]]; then
    if [[ ! -f "$ICON_OUT" || "$PROJECT_ROOT/assets/icon-source.png" -nt "$ICON_OUT" ]]; then
        echo "→ generating $ICON_OUT"
        "$PROJECT_ROOT/scripts/build-icon.sh"
    fi
    cp "$ICON_OUT" "$APP_BUNDLE/Contents/Resources/Slate.icns"
fi

echo "→ ad-hoc code-signing"
codesign --force --sign - --deep "$APP_BUNDLE"

echo "✓ built $APP_BUNDLE"
echo "  open: open \"$APP_BUNDLE\""
