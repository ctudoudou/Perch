#!/bin/bash
# Builds Perch.app. SwiftPM produces a bare executable; a notch app needs a real
# bundle so it can be an accessory app (no Dock icon) and launch from Finder.
#
#   ./build-app.sh                 debug, host architecture
#   ./build-app.sh release         release, host architecture
#   ./build-app.sh release --universal   release, arm64 + x86_64
set -euo pipefail

CONFIG="${1:-release}"
UNIVERSAL="${2:-}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Perch.app"

ARCH_ARGS=()
if [ "$UNIVERSAL" = "--universal" ]; then
  ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" --package-path "$ROOT" "${ARCH_ARGS[@]}"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" "${ARCH_ARGS[@]}" --show-bin-path)/Perch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Perch"
cp "$ROOT/Sources/Perch/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/Perch/Resources/Perch.icns" "$APP/Contents/Resources/Perch.icns"

# Ad-hoc signature. Enough to run locally; replace with a Developer ID identity
# and notarize to distribute without a Gatekeeper prompt.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
file "$APP/Contents/MacOS/Perch" | sed 's/^/  /'
