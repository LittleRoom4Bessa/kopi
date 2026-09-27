#!/bin/bash
# Builds kopi and bundles it as Kopi.app (menu bar agent, LSUIElement).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP_DIR=".build/Kopi.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp ".build/release/kopi" "$APP_DIR/Contents/MacOS/Kopi"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Ad-hoc sign so macOS treats it as a stable app (notifications, Gatekeeper caching).
codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR"
echo "Run with: open $APP_DIR"
