#!/usr/bin/env bash
# Build the WaveWrangler macOS app (Debug by default) with ad-hoc signing and isolated DerivedData.
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
JOBS="${WW_JOBS:-4}"
DERIVED_DATA="${WW_DERIVED_DATA:-$ROOT/.build/DerivedData}"

cd "$ROOT"
xcodebuild \
  -project WaveWrangler.xcodeproj \
  -scheme WaveWrangler \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -jobs "$JOBS" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  build

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/WaveWrangler.app"
VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
BUILD=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")
printf '\nBuilt WaveWrangler %s (build %s)\nApp: %s\n' "$VERSION" "$BUILD" "$APP"
