#!/usr/bin/env bash
# One-shot WWRender revision-3 holdout with contemporaneous per-PID CPU samples.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# != 1 ]]; then
  echo "usage: scripts/render-holdout-3.sh <new evidence directory outside the repo>" >&2
  exit 2
fi
OUTPUT="$1"
cd "$ROOT"
if [[ "$OUTPUT" != /* ]] || [[ "$OUTPUT" == "$ROOT" || "$OUTPUT" == "$ROOT/"* ]]; then
  echo "holdout evidence directory must be an absolute path outside the repository" >&2
  exit 2
fi
if [[ -e "$OUTPUT" ]]; then
  echo "holdout evidence directory already exists; refusing a second attempt: $OUTPUT" >&2
  exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "holdout requires a clean committed tree" >&2
  exit 2
fi
FREEZE="docs/m2/fixtures/m2-freeze-render-3.json"
if ! git cat-file -e "HEAD:$FREEZE"; then
  echo "revision-3 freeze must be committed before the holdout" >&2
  exit 2
fi
SOURCE_TREE="$(git rev-parse HEAD:Packages/WaveWranglerKit/Sources/WWRender)"
TEST_TREE="$(git rev-parse HEAD:Packages/WaveWranglerKit/Tests/WWRenderTests)"
RUNNER_SHA="$(shasum -a 256 "$ROOT/scripts/render-holdout-3.sh" | awk '{print $1}')"
python3 - "$FREEZE" "$SOURCE_TREE" "$TEST_TREE" "$RUNNER_SHA" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as record:
    freeze = json.load(record)
for path, expected in (("Sources/WWRender", sys.argv[2]), ("Tests/WWRenderTests", sys.argv[3])):
    if freeze["pinnedTrees"][path] != expected:
        raise SystemExit(f"{path} differs from frozen pin")
if freeze["cpuTelemetry"]["runnerSHA256"] != sys.argv[4]:
    raise SystemExit("runner differs from frozen pin")
PY

LOAD="$(sysctl -n vm.loadavg | awk '{print $2}')"
if ! [[ "$LOAD" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
   ! awk -v load="$LOAD" 'BEGIN { exit !(load + 0 <= 24) }'; then
  echo "working Mac one-minute load $LOAD exceeds frozen limit 24; holdout not started" >&2
  exit 2
fi
OTHER_BUILDS="$(ps -A -o comm= | awk '/\/(xcodebuild|swift-build|swift-test)$/ { n++ } END { print n+0 }')"
OTHER_HELPERS="$(ps -A -o comm= | awk '/swiftpm-testing-helper$/ { n++ } END { print n+0 }')"
if (( OTHER_BUILDS > 2 || OTHER_HELPERS > 0 )); then
  echo "working Mac has $OTHER_BUILDS native builds and $OTHER_HELPERS test helpers; holdout not started" >&2
  exit 2
fi

mkdir "$OUTPUT"
{
  printf 'freezeSHA=%s\n' "$(git rev-parse HEAD)"
  printf 'sourceTree=%s\ntestTree=%s\nrunnerSHA256=%s\n' "$SOURCE_TREE" "$TEST_TREE" "$RUNNER_SHA"
  printf 'host=%s\n' "$(hostname)"
  sw_vers
  xcodebuild -version
  swift --version
  printf 'oneMinuteLoad=%s\notherNativeBuilds=%s\notherTestHelpers=%s\n' "$LOAD" "$OTHER_BUILDS" "$OTHER_HELPERS"
  printf 'command=WW_M2_RENDER_3_HOLDOUT=1 WW_RENDER_RECORDS_DIR=<evidence directory> SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 swift test --package-path Packages/WaveWranglerKit --scratch-path .build/swiftpm --jobs 4 --no-parallel --filter holdoutSplitMeetsEveryFrozenGate\n'
} >"$OUTPUT/preflight.txt"
printf 'epochSeconds\tpid\tppid\tpgid\tcpuPercent\tcommand\n' >"$OUTPUT/cpu.tsv"

START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
WW_M2_RENDER_3_HOLDOUT=1 WW_RENDER_RECORDS_DIR="$OUTPUT" \
  SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
  perl -MPOSIX=setpgid -e 'setpgid(0,0) == 0 or die "setpgid: $!"; exec @ARGV or die "exec: $!"' \
  swift test --package-path Packages/WaveWranglerKit --scratch-path .build/swiftpm \
  --jobs 4 --no-parallel --filter holdoutSplitMeetsEveryFrozenGate >"$OUTPUT/run.log" 2>&1 &
RUN_PID=$!

while ps -p "$RUN_PID" -o pid= >/dev/null 2>&1; do
  SAMPLE_EPOCH="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
  if ! ps -A -o pid=,ppid=,pgid=,%cpu=,comm= 2>>"$OUTPUT/telemetry-errors.log" |
       awk -v root="$RUN_PID" -v time="$SAMPLE_EPOCH" '{
         pid[NR] = $1; parent[NR] = $2; group[NR] = $3; cpu[NR] = $4; command[NR] = $5
       }
       END {
         descendants[root] = 1
         changed = 1
         while (changed) {
           changed = 0
           for (i = 1; i <= NR; i++) {
             if (parent[i] in descendants && !(pid[i] in descendants)) {
               descendants[pid[i]] = 1
               changed = 1
             }
           }
         }
         for (i = 1; i <= NR; i++) if (pid[i] in descendants) {
           printf "%s\t%s\t%s\t%s\t%s\t%s\n", time, pid[i], parent[i], group[i], cpu[i], command[i]
         }
       }' >>"$OUTPUT/cpu.tsv"; then
    printf 'ps failed at epoch %s\n' "$SAMPLE_EPOCH" >>"$OUTPUT/telemetry-errors.log"
  fi
  sleep 0.25
done

if wait "$RUN_PID"; then RUN_EXIT=0; else RUN_EXIT=$?; fi
END_EPOCH="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'startUTC=%s\nendUTC=%s\nstartEpoch=%s\nendEpoch=%s\nruntimeSeconds=%.3f\nexitCode=%d\n' \
  "$START_UTC" "$END_UTC" "$START_EPOCH" "$END_EPOCH" \
  "$(awk -v start="$START_EPOCH" -v end="$END_EPOCH" 'BEGIN { print end-start }')" "$RUN_EXIT" >"$OUTPUT/timing.txt"

if [[ -s "$OUTPUT/telemetry-errors.log" ]] ||
   ! awk -F '\t' -v start="$START_EPOCH" -v end="$END_EPOCH" '
     NR > 1 {
       if (count && $1 - previous > 1) bad = 1
       if (!count) first = $1
       previous = $1
       count++
       if ($5 !~ /^[0-9]+([.][0-9]+)?$/) bad = 1
       if ($5 + 0 > peak) { peak = $5 + 0; peakPID = $2; peakCommand = $6 }
       if ($6 ~ /swiftpm-testing-helper/) helpers++
     }
     END {
       printf "pidSamples=%d\nhelperSamples=%d\npeakPIDCPUPercent=%.1f\npeakPID=%s\npeakCommand=%s\n", count, helpers, peak, peakPID, peakCommand
       if (!count || !helpers || first - start > 1 || end - previous > 1 || bad) exit 1
     }' "$OUTPUT/cpu.tsv" >"$OUTPUT/cpu-summary.txt"; then
  printf 'INCOMPLETE: missing or gapped contemporaneous per-PID CPU telemetry\n' >"$OUTPUT/verdict.txt"
  exit 2
fi
if (( RUN_EXIT != 0 )) ||
   [[ ! -f "$OUTPUT/ww-018-holdout-3.jsonl" ]] ||
   ! grep -Fq 'Test holdoutSplitMeetsEveryFrozenGate() passed' "$OUTPUT/run.log"; then
  printf 'FAIL: holdout test failed, skipped, or did not publish records (exit %d)\n' "$RUN_EXIT" >"$OUTPUT/verdict.txt"
  exit 1
fi
if ! awk -F= '/^peakPIDCPUPercent=/ { exit !($2 + 0 <= 400) }' "$OUTPUT/cpu-summary.txt"; then
  printf 'FAIL: sampled per-PID CPU exceeded 400%%\n' >"$OUTPUT/verdict.txt"
  exit 1
fi
printf 'PASS: holdout objective test and contemporaneous sampled per-PID CPU <=400%%; family peak uses existing same-source evidence; listening remains BLOCKED\n' >"$OUTPUT/verdict.txt"
