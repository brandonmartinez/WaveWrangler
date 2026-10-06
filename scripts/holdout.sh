#!/usr/bin/env bash
# M1 durability post-freeze holdout runner (registry m1-freeze-1, WW-003 protocol).
#
# Usage: scripts/holdout.sh [--split calibration|holdout] [--package] [--timing] [--native] [--icloud]
#   --package  WWPersistence holdout families (synthetic, temp dirs)            [default when no pass is given]
#   --timing   serialized timing pass: M1-DUR-002 and M1-SCALE-001 (model level) [default when no pass is given]
#   --native   NSDocument cells of M1-DUR-006 and M1-DUR-008: launches the Debug app (GUI lock required)
#   --icloud   M1-DUR-024 observed iCloud Drive trial (grant C; synthetic; persistence/ subfolder deleted after).
#              Live-provider test: runs only with WW_LIVE_PROVIDER_TESTS=1 (#146); skipped otherwise.
#
# The holdout split runs once per frozen revision and must run on a clean commit that contains the freeze
# merge (2fcf4d7). Results: .build/holdout/<split>/ (JSON lines + run metadata).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${WW_JOBS:-4}"
SPLIT=calibration
PASSES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --split) SPLIT="$2"; shift 2 ;;
    --package|--timing|--native|--icloud) PASSES+=("${1#--}"); shift ;;
    *) echo "usage: scripts/holdout.sh [--split calibration|holdout] [--package] [--timing] [--native] [--icloud]" >&2; exit 2 ;;
  esac
done
[[ ${#PASSES[@]} -eq 0 ]] && PASSES=(package timing)
[[ "$SPLIT" == calibration || "$SPLIT" == holdout ]] || { echo "error: --split must be calibration or holdout" >&2; exit 2; }

cd "$ROOT"
FREEZE=2fcf4d7
if [[ "$SPLIT" == holdout ]]; then
  git merge-base --is-ancestor "$FREEZE" HEAD || { echo "error: HEAD does not contain the freeze merge $FREEZE" >&2; exit 2; }
  [[ -z "$(git status --porcelain)" ]] || { echo "error: holdout runs need a clean worktree (tree IDs must match what ran)" >&2; exit 2; }
fi

OUT="$ROOT/.build/holdout/$SPLIT"
mkdir -p "$OUT"
PKG_RESULTS="$ROOT/Packages/WaveWranglerKit/.build/holdout/results-$SPLIT.jsonl"

tree() { git rev-parse "HEAD:$1" 2>/dev/null || echo "missing"; }
{
  echo "{"
  echo "  \"commit\": \"$(git rev-parse HEAD)\","
  echo "  \"containsFreeze\": \"$FREEZE\","
  echo "  \"split\": \"$SPLIT\","
  echo "  \"startedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"host\": {\"os\": \"$(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))\", \"xcode\": \"$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')\", \"swift\": \"$(swift --version 2>&1 | head -1 | sed 's/"/\\"/g')\", \"cpu\": \"$(sysctl -n machdep.cpu.brand_string)\", \"cores\": $(sysctl -n hw.ncpu), \"memoryBytes\": $(sysctl -n hw.memsize)},"
  echo "  \"trees\": {"
  for path in Packages/WaveWranglerKit/Tests/WWPersistenceTests Packages/WaveWranglerKit/Sources/WWPersistenceProbe Packages/WaveWranglerKit/Sources/WWPersistence \
              Packages/WaveWranglerKit/Sources/WWOrganizer Packages/WaveWranglerKit/Sources/WWCore WaveWrangler/Document WaveWranglerTests WaveWranglerUITests; do
    echo "    \"$path\": \"$(tree "$path")\","
  done
  echo "    \"scripts/holdout.sh\": \"$(tree scripts/holdout.sh)\""
  echo "  },"
  echo "  \"passes\": \"${PASSES[*]}\""
  echo "}"
} > "$OUT/run-$(date -u +%Y%m%dT%H%M%SZ).json"

run_package() {
  local filter="$1"; shift
  env WW_HOLDOUT=1 WW_HOLDOUT_SPLIT="$SPLIT" "$@" swift test \
    --package-path "$ROOT/Packages/WaveWranglerKit" --scratch-path "$ROOT/.build/swiftpm" --jobs "$JOBS" --filter "$filter"
}

rm -f "$PKG_RESULTS"
for pass in "${PASSES[@]}"; do
  case "$pass" in
    package)
      echo "==> holdout ($SPLIT): package families"
      run_package 'HoldoutSaveLifecycleTests|HoldoutOpenRecoveryTests|HoldoutBoundaryTests|HoldoutProcessTests' || echo "PACKAGE PASS REPORTED FAILURES" >&2
      ;;
    timing)
      echo "==> holdout ($SPLIT): serialized timing pass"
      run_package 'HoldoutTimingTests' WW_TIMING_TESTS=1 || echo "TIMING PASS REPORTED FAILURES" >&2
      ;;
    icloud)
      # Live iCloud Drive (real provider, brctl): opt-in only (#146).
      if [[ "${WW_LIVE_PROVIDER_TESTS:-}" != 1 ]]; then
        echo "==> holdout ($SPLIT): iCloud Drive observed trial SKIPPED (live-provider test; set WW_LIVE_PROVIDER_TESTS=1 to opt in, #146)"
        continue
      fi
      echo "==> holdout ($SPLIT): iCloud Drive observed trial (grant C)"
      run_package 'HoldoutICloudTrialTests' WW_ICLOUD_TRIAL=1 || echo "ICLOUD PASS REPORTED FAILURES" >&2
      ls -la "$HOME/Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial/" > "$OUT/icloud-trial-root-after.txt" 2>&1 || true
      ;;
    native)
      echo "==> holdout ($SPLIT): native NSDocument runner (GUI lock required)"
      "$ROOT/scripts/build.sh" Debug > "$OUT/native-build.log" 2>&1
      APP="$ROOT/.build/DerivedData/Build/Products/Debug/WaveWrangler.app"
      CONTAINER_RESULTS="$HOME/Library/Containers/com.brandonmartinez.wavewrangler/Data/Library/Application Support/WaveWrangler-UITests/holdout/native-results.jsonl"
      rm -f "$CONTAINER_RESULTS"
      "$APP/Contents/MacOS/WaveWrangler" -WWUITestHooks YES -WWNativeHoldout "$SPLIT" -ApplePersistenceIgnoreState YES > "$OUT/native-app.log" 2>&1 &
      APP_PID=$!
      for _ in $(seq 1 3600); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 1; done
      if kill -0 "$APP_PID" 2>/dev/null; then kill "$APP_PID"; echo "NATIVE RUNNER TIMED OUT" >&2; fi
      wait "$APP_PID" || true
      cp "$CONTAINER_RESULTS" "$OUT/native-results.jsonl" || echo "NATIVE RESULTS MISSING" >&2
      ;;
  esac
done
[[ -f "$PKG_RESULTS" ]] && cat "$PKG_RESULTS" >> "$OUT/package-results.jsonl"
echo "==> results in $OUT"
