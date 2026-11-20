#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/OsmoBar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

echo "Building OsmoBar (release)..."
cd "$ROOT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/OsmoBar"

echo "Packaging $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/OsmoBar"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/OsmoBar"

echo "Ad-hoc signing bundle..."
codesign --force --deep --sign - "$APP_DIR"

echo "Done! Launch with:"
echo "  open \"$APP_DIR\""
