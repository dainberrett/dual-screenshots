#!/bin/bash
# Builds DualScreenshots and assembles a runnable .app bundle.
# Usage: ./build.sh [debug|release]   (default: release)

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Dual Screenshots"
BUNDLE_ID="com.dualscreenshots.app"
EXECUTABLE="DualScreenshots"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Compiling ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN_PATH="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/$EXECUTABLE"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
echo "    Run it with:  open \"$APP\""
