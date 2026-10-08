#!/usr/bin/env bash
# Run WaveWranglerKit package tests, then the unhosted WaveWranglerTests unit tests.
# UI tests launch the app and are NOT run by default. `--ui` runs ONLY the XCUITests (GUI); use it only
# when GUI launch is permitted and the GUI lock is held.
# Usage: scripts/test.sh [--package-only] [--ui [-only-testing:WaveWranglerUITests/Class/test]]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${WW_JOBS:-4}"
ESTIMATOR_MAX_CONCURRENCY="${WW_ESTIMATOR_MAX_CONCURRENCY:-2}"
ESTIMATOR_CONCURRENCY_GRANT="${WW_ESTIMATOR_CONCURRENCY_GRANT:-}"

case "$ESTIMATOR_MAX_CONCURRENCY" in
  ''|*[!0-9]*)
    echo "WW_ESTIMATOR_MAX_CONCURRENCY must be an integer from 1 to 4 (got '$ESTIMATOR_MAX_CONCURRENCY')" >&2
    exit 2
    ;;
esac
if (( ESTIMATOR_MAX_CONCURRENCY < 1 || ESTIMATOR_MAX_CONCURRENCY > 4 )); then
  echo "WW_ESTIMATOR_MAX_CONCURRENCY must be an integer from 1 to 4 (got '$ESTIMATOR_MAX_CONCURRENCY')" >&2
  exit 2
fi
if (( ESTIMATOR_MAX_CONCURRENCY > 2 )) && [[ "$ESTIMATOR_CONCURRENCY_GRANT" != "$ESTIMATOR_MAX_CONCURRENCY" ]]; then
  echo "WW_ESTIMATOR_MAX_CONCURRENCY above the default of 2 requires WW_ESTIMATOR_CONCURRENCY_GRANT to match the requested value" >&2
  exit 2
fi
export WW_ESTIMATOR_MAX_CONCURRENCY="$ESTIMATOR_MAX_CONCURRENCY"
export WW_ESTIMATOR_CONCURRENCY_GRANT="$ESTIMATOR_CONCURRENCY_GRANT"
# Test processes can start their own bounded tasks. Keep one test case at a time so separate pipeline
# cases cannot stack their internal work; --jobs limits compilation, not the test process.
TEST_WORKERS="${WW_TEST_WORKERS:-1}"
SEGMENT_MAX_CONCURRENCY="${WW_SEGMENT_MAX_CONCURRENCY:-3}"
FREEZE_MAX_CONCURRENCY="${WW_M2_FREEZE_MAX_CONCURRENCY:-2}"
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

if [[ "$UI" == 0 ]]; then
  for setting in "WW_TEST_WORKERS:$TEST_WORKERS:1" "WW_SEGMENT_MAX_CONCURRENCY:$SEGMENT_MAX_CONCURRENCY:3" "WW_M2_FREEZE_MAX_CONCURRENCY:$FREEZE_MAX_CONCURRENCY:2"; do
    IFS=: read -r name value maximum <<<"$setting"
    if [[ ! "$value" =~ ^[1-3]$ ]] || (( value > maximum )); then
      echo "$name must be an integer from 1 to $maximum (got '$value')" >&2
      exit 2
    fi
  done
  export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="$TEST_WORKERS"
  export WW_SEGMENT_MAX_CONCURRENCY="$SEGMENT_MAX_CONCURRENCY"
  export WW_M2_FREEZE_MAX_CONCURRENCY="$FREEZE_MAX_CONCURRENCY"
fi

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
  --jobs "$JOBS" \
  --no-parallel

# The CPU-heavy WW-016 estimator suites run alone after the ordinary package suite. Calibration schedules at most
# WW_ESTIMATOR_MAX_CONCURRENCY cases in flight (default 2, hard maximum 4); higher values require a matching
# explicit WW_ESTIMATOR_CONCURRENCY_GRANT. Scenario tests are serialized and this pass disables test parallelism.
echo "==> swift test estimator pass: ScenarioTests, CalibrationTests (max ${WW_ESTIMATOR_MAX_CONCURRENCY} cases)"
ESTIMATOR_LOG="$(mktemp)"
WW_ESTIMATOR_TESTS=1 swift test \
  --package-path "$ROOT/Packages/WaveWranglerKit" \
  --scratch-path "$ROOT/.build/swiftpm" \
  --jobs "$JOBS" \
  --no-parallel \
  --filter 'WWAlignEstimateTests\.(ScenarioTests|CalibrationTests)' 2>&1 | tee "$ESTIMATOR_LOG"
for estimator_suite in 'Estimator scenarios' 'Estimator calibration'; do
  if ! grep -q "Suite \"$estimator_suite\" passed" "$ESTIMATOR_LOG"; then
    echo "estimator pass: '$estimator_suite' did not run and pass" >&2
    rm -f "$ESTIMATOR_LOG"
    exit 1
  fi
done
rm -f "$ESTIMATOR_LOG"

# WW-017 discontinuity segmentation (calibration against planted truth, detection-floor sweep, steps beside
# target silence) is CPU-heavy for minutes; it runs alone for the same reason, its suites one after another
# (--no-parallel), each with at most WW_SEGMENT_MAX_CONCURRENCY (default 3 here) cases in flight. The log check fails
# the script if the selected suites were skipped.
# On CI (CI=true) WW_SEGMENT_SWEEPS defaults to 0: only the gated calibration runs, keeping the job well inside its
# timeout. The floor and edge-silence sweeps are skipped there, but the always-on cheap test
# committedRecordsReproduceTheReportedCalibration still re-checks their committed records. Locally the default is 1
# (all three suites).
if [[ "${CI:-}" == true ]]; then SEGMENT_SWEEPS="${WW_SEGMENT_SWEEPS:-0}"; else SEGMENT_SWEEPS="${WW_SEGMENT_SWEEPS:-1}"; fi
case "$SEGMENT_SWEEPS" in
  0)
    SEGMENT_FILTER='WWAlignSegmentTests\.CalibrationTests'
    SEGMENT_REQUIRED=(calibrationAgainstPlantedTruth)
    echo "==> swift test segment pass: CalibrationTests (WW_SEGMENT_SWEEPS=0: floor and edge-silence sweeps skipped)"
    ;;
  1)
    SEGMENT_FILTER='WWAlignSegmentTests\.(CalibrationTests|FloorSweepTests|EdgeSilenceTests)'
    SEGMENT_REQUIRED=(calibrationAgainstPlantedTruth detectionFloor silenceBesideAJumpNeverBridgesIt)
    echo "==> swift test segment pass: CalibrationTests, FloorSweepTests, EdgeSilenceTests"
    ;;
  *)
    echo "WW_SEGMENT_SWEEPS must be 0 or 1 (got '$SEGMENT_SWEEPS')" >&2
    exit 2
    ;;
esac
SEGMENT_LOG="$(mktemp)"
WW_SEGMENT_TESTS=1 swift test \
  --package-path "$ROOT/Packages/WaveWranglerKit" \
  --scratch-path "$ROOT/.build/swiftpm" \
  --jobs "$JOBS" \
  --no-parallel \
  --filter "$SEGMENT_FILTER" 2>&1 | tee "$SEGMENT_LOG"
for segment_test in "${SEGMENT_REQUIRED[@]}"; do
  if ! grep -q "Test $segment_test() passed" "$SEGMENT_LOG"; then
    echo "segment pass: $segment_test did not run and pass" >&2
    rm -f "$SEGMENT_LOG"
    exit 1
  fi
done
rm -f "$SEGMENT_LOG"

# WW-021 analysis memory bound: three 14-channel 75-minute synthetic groups analysed at the default
# configuration must peak well under 1 GiB resident. Runs alone so no other suite inflates the process peak.
echo "==> swift test pipeline memory pass: PipelineMemoryTests"
PIPELINE_LOG="$(mktemp)"
WW_PIPELINE_HEAVY_TESTS=1 swift test \
  --package-path "$ROOT/Packages/WaveWranglerKit" \
  --scratch-path "$ROOT/.build/swiftpm" \
  --jobs "$JOBS" \
  --no-parallel \
  --filter 'WWAlignPipelineTests\.PipelineMemoryTests' 2>&1 | tee "$PIPELINE_LOG"
if ! grep -q 'peaks well under 1 GiB" passed' "$PIPELINE_LOG"; then
  echo "pipeline memory pass did not run and pass" >&2
  rm -f "$PIPELINE_LOG"
  exit 1
fi
rm -f "$PIPELINE_LOG"

# WW-023 full-length aligned-asset envelope: a mixed-rate, three-recorder 75-minute group is rendered through
# the real pipeline path. At Debug speed it cannot fit CI's 60-minute job, so CI relies on the always-on short
# path coverage and this recorded local gate. Developer runs execute it alone in an optimized, testable build.
if [[ "${CI:-}" == true ]]; then
  echo "==> pipeline 75-minute render pass skipped on CI (local bounded measurement; see ww-021 evidence)"
else
  echo "==> swift test pipeline 75-minute render pass: PipelineRender75Tests"
  PIPELINE_RENDER_LOG="$(mktemp)"
  WW_PIPELINE_RENDER75=1 swift test \
    --package-path "$ROOT/Packages/WaveWranglerKit" \
    --scratch-path "$ROOT/.build/swiftpm" \
    --configuration release \
    -Xswiftc -enable-testing \
    -Xswiftc -DDEBUG \
    --jobs "$JOBS" \
    --no-parallel \
    --filter 'WWAlignPipelineTests\.PipelineRender75Tests' 2>&1 | tee "$PIPELINE_RENDER_LOG"
  PIPELINE_RENDER_REQUIRED=(
    "A mixed-rate three-recorder group renders all six channels for 75 minutes within the engineering envelope"
    "Cancellation remains responsive after a 75-minute aligned render has begun"
  )
  for pipeline_render_test in "${PIPELINE_RENDER_REQUIRED[@]}"; do
    if ! grep -q "Test \"$pipeline_render_test\" passed" "$PIPELINE_RENDER_LOG"; then
      echo "pipeline 75-minute render pass: '$pipeline_render_test' did not run and pass" >&2
      rm -f "$PIPELINE_RENDER_LOG"
      exit 1
    fi
  done
  rm -f "$PIPELINE_RENDER_LOG"
fi

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

# WW-050 decode (M2-DECODE-002) and WW-015 time-map (M2-TIMEMAP-001) calibration splits run alone, one after the
# other: the decode split decodes synthetic files and the time-map split runs exact round trips.
# Both use WW_M2_FREEZE_MAX_CONCURRENCY (default 2 here), below their test-side maximum of 4.
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
