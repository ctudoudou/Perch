#!/bin/bash
# Builds Perch.app. SwiftPM produces a bare executable; a notch app needs a
# real bundle so it can be an accessory app (no Dock icon) and be launched
# normally from Finder.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Perch.app"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Perch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Perch"
cp "$ROOT/Sources/Perch/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/Perch/Resources/Perch.icns" "$APP/Contents/Resources/Perch.icns"

# Ad-hoc signature: enough for local use; replace with a Developer ID identity
# to distribute.
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
