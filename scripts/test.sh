#!/usr/bin/env bash
# Run WaveWranglerKit package tests, then the unhosted WaveWranglerTests unit tests.
# UI tests launch the app and are NOT run by default; --ui is reserved until GUI launch is permitted.
# Usage: scripts/test.sh [--package-only] [--ui]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${WW_JOBS:-4}"
DERIVED_DATA="${WW_DERIVED_DATA:-$ROOT/.build/DerivedData}"
PACKAGE_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --package-only) PACKAGE_ONLY=1 ;;
    --ui)
      echo "error: --ui is reserved; UI tests are not enabled until GUI launch is permitted." >&2
      exit 2
      ;;
    *)
      echo "usage: scripts/test.sh [--package-only] [--ui]" >&2
      exit 2
      ;;
  esac
done

echo "==> swift test (Packages/WaveWranglerKit)"
swift test \
  --package-path "$ROOT/Packages/WaveWranglerKit" \
  --scratch-path "$ROOT/.build/swiftpm" \
  --jobs "$JOBS"

if [[ "$PACKAGE_ONLY" == 1 ]]; then
  exit 0
fi

echo "==> xcodebuild test (WaveWranglerTests only)"
cd "$ROOT"
xcodebuild \
  -project WaveWrangler.xcodeproj \
  -scheme WaveWrangler \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -jobs "$JOBS" \
  -only-testing:WaveWranglerTests \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  test
