#!/usr/bin/env bash
# Run WaveWranglerKit package tests, then the unhosted WaveWranglerTests unit tests.
# UI tests launch the app and are NOT run by default. `--ui` runs ONLY the XCUITests (GUI); use it only
# when GUI launch is permitted and the GUI lock is held.
# Usage: scripts/test.sh [--package-only] [--ui [-only-testing:WaveWranglerUITests/Class/test]]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${WW_JOBS:-4}"
DERIVED_DATA="${WW_DERIVED_DATA:-$ROOT/.build/DerivedData}"
PACKAGE_ONLY=0
UI=0
UI_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --package-only) PACKAGE_ONLY=1 ;;
    --ui) UI=1 ;;
    -only-testing:WaveWranglerUITests*) UI_ARGS+=("$arg") ;;
    *)
      echo "usage: scripts/test.sh [--package-only] [--ui [-only-testing:WaveWranglerUITests/...]]" >&2
      exit 2
      ;;
  esac
done

if [[ "$UI" == 1 ]]; then
  echo "==> swift build wwpersist-probe (synthetic fixtures for UI tests)"
  swift build \
    --package-path "$ROOT/Packages/WaveWranglerKit" \
    --scratch-path "$ROOT/.build/swiftpm" \
    --jobs "$JOBS" \
    --product wwpersist-probe
  PROBE="$(swift build --package-path "$ROOT/Packages/WaveWranglerKit" --scratch-path "$ROOT/.build/swiftpm" --show-bin-path)/wwpersist-probe"
  echo "==> xcodebuild test (WaveWranglerUITests; launches the app)"
  cd "$ROOT"
  if [[ ${#UI_ARGS[@]} -eq 0 ]]; then UI_ARGS=(-only-testing:WaveWranglerUITests); fi
  TEST_RUNNER_WW_PROBE="$PROBE" xcodebuild \
    -project WaveWrangler.xcodeproj \
    -scheme WaveWranglerUITests \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -jobs "$JOBS" \
    "${UI_ARGS[@]}" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$ROOT/.build/UITests-$(date +%Y%m%d-%H%M%S).xcresult" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    test
  exit 0
fi

echo "==> swift test (Packages/WaveWranglerKit)"
swift test \
  --package-path "$ROOT/Packages/WaveWranglerKit" \
  --scratch-path "$ROOT/.build/swiftpm" \
  --jobs "$JOBS"

# The CPU-heavy WW-016 estimator suites (scenarios, calibration) run alone after the parallel suite so their
# signal processing never starves other suites' liveness waits on a small CI runner.
echo "==> swift test estimator pass: ScenarioTests, CalibrationTests"
WW_ESTIMATOR_TESTS=1 swift test \
  --package-path "$ROOT/Packages/WaveWranglerKit" \
  --scratch-path "$ROOT/.build/swiftpm" \
  --jobs "$JOBS" \
  --filter 'WWAlignEstimateTests\.(ScenarioTests|CalibrationTests)'

# Timing gates (WW-005 ≤2 s edit-to-quiescent checkpoint, publication cost, library scale p95), the WW-016
# estimator throughput report and the WW-018 render family peak run one at a time after the parallel suite, so
# the fault harness's own I/O does not distort the measurements.
for timing_test in editToQuiescentCheckpointLatency publicationPipelineCost hundredShowsThousandSourceRefs estimatorThroughputBenchmark renderFamilyPeakAndThroughput; do
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
