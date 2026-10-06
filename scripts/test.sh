#!/usr/bin/env bash
# Run WaveWranglerKit package tests, then the unhosted WaveWranglerTests unit tests.
# UI tests launch the app and are NOT run by default. `--ui` runs ONLY the XCUITests (GUI); use it only
# when GUI launch is permitted and the GUI lock is held.
# Usage: scripts/test.sh [--package-only] [--ui [-only-testing:WaveWranglerUITests/Class/test]]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${WW_JOBS:-4}"
# Compute budget: Swift Testing runs at most this many tests at once (its default is unbounded). `--num-workers`
# bounds XCTest only, so the width goes through Swift Testing's own environment switch.
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${WW_TEST_WORKERS:-4}"
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

# WW-017 discontinuity segmentation (calibration against planted truth, detection-floor sweep, steps beside
# target silence) is CPU-heavy for minutes; it runs alone for the same reason, its suites one after another
# (--no-parallel), each with at most WW_SEGMENT_MAX_CONCURRENCY (default 4) cases in flight. The log check fails
# the script if the suites were skipped.
echo "==> swift test segment pass: CalibrationTests, FloorSweepTests, EdgeSilenceTests"
SEGMENT_LOG="$(mktemp)"
WW_SEGMENT_TESTS=1 swift test \
  --package-path "$ROOT/Packages/WaveWranglerKit" \
  --scratch-path "$ROOT/.build/swiftpm" \
  --jobs "$JOBS" \
  --no-parallel \
  --filter 'WWAlignSegmentTests\.(CalibrationTests|FloorSweepTests|EdgeSilenceTests)' 2>&1 | tee "$SEGMENT_LOG"
for segment_test in calibrationAgainstPlantedTruth detectionFloor silenceBesideAJumpNeverBridgesIt; do
  if ! grep -q "Test $segment_test() passed" "$SEGMENT_LOG"; then
    echo "segment pass: $segment_test did not run and pass" >&2
    rm -f "$SEGMENT_LOG"
    exit 1
  fi
done
rm -f "$SEGMENT_LOG"

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

# WW-018 render calibration (M2-RENDER-001 calibration split) is CPU-bound for tens of seconds; it runs alone
# so it cannot starve the time-limited suites of the parallel pass.
echo "==> swift test render calibration pass"
CALIBRATION_LOG="$(mktemp)"
WW_RENDER_CALIBRATION=1 swift test \
  --package-path "$ROOT/Packages/WaveWranglerKit" \
  --scratch-path "$ROOT/.build/swiftpm" \
  --jobs "$JOBS" \
  --filter calibrationSplitMeetsEveryObjectiveGate 2>&1 | tee "$CALIBRATION_LOG"
if ! grep -q 'Test calibrationSplitMeetsEveryObjectiveGate() passed' "$CALIBRATION_LOG"; then
  echo "render calibration pass did not run and pass" >&2
  rm -f "$CALIBRATION_LOG"
  exit 1
fi
rm -f "$CALIBRATION_LOG"

# WW-050 decode (M2-DECODE-001) and WW-015 time-map (M2-TIMEMAP-001) calibration splits run alone, one after the
# other: the decode split decodes real files and the time-map split runs hundreds of thousands of exact round trips.
for freeze_pass in "WW_DECODE_CALIBRATION DecodeCalibrationTests" "WW_TIMEMAP_CALIBRATION TimeMapCalibrationTests"; do
  read -r switch suite <<<"$freeze_pass"
  echo "==> swift test calibration pass: $suite"
  CALIBRATION_LOG="$(mktemp)"
  env "$switch=1" swift test \
    --package-path "$ROOT/Packages/WaveWranglerKit" \
    --scratch-path "$ROOT/.build/swiftpm" \
    --jobs "$JOBS" \
    --filter "$suite/calibrationSplitMeetsEveryGate" 2>&1 | tee "$CALIBRATION_LOG"
  if ! grep -q 'Test calibrationSplitMeetsEveryGate() passed' "$CALIBRATION_LOG"; then
    echo "$suite calibration pass did not run and pass" >&2
    rm -f "$CALIBRATION_LOG"
    exit 1
  fi
  rm -f "$CALIBRATION_LOG"
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
