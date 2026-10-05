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

# Timing gates (WW-005 ≤2 s edit-to-quiescent checkpoint, publication cost, library scale p95) run one at a
# time after the parallel suite, so the fault harness's own I/O does not distort the measurements.
for timing_test in editToQuiescentCheckpointLatency publicationPipelineCost hundredShowsThousandSourceRefs; do
  echo "==> swift test timing pass: $timing_test"
  WW_TIMING_TESTS=1 swift test \
    --package-path "$ROOT/Packages/WaveWranglerKit" \
    --scratch-path "$ROOT/.build/swiftpm" \
    --jobs "$JOBS" \
    --filter "$timing_test"
done

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
