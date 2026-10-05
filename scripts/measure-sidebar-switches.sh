#!/usr/bin/env bash
# Native Library sidebar-selection benchmark (WW-007 / #106). Launches the Debug app directly (no XCUITest)
# with the synthetic lib100 library and the Debug-only -WWMeasureSidebarSwitches hook, which changes the
# sidebar selection N times (walking down and up the 8 rows like SCALE-001), logs one WWBENCH line per switch
# and a summary, then quits. GUI use: take the GUI lock first. Synthetic data only; UI-test storage.
#
# Usage: scripts/measure-sidebar-switches.sh [--size WxH ...] [--switches N] [--swiftui-table]
#   --size           Library window content size; repeatable (default: 1000x600, the window's default size)
#   --switches       switches per run (default 100)
#   --swiftui-table  A/B baseline: the previous SwiftUI Table entry list (Debug-only switch)
# Build first with scripts/build.sh (Debug). Results: .build/sidebar-switches/<label>.log
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${WW_DERIVED_DATA:-$ROOT/.build/DerivedData}/Build/Products/Debug/WaveWrangler.app/Contents/MacOS/WaveWrangler"
SIZES=()
SWITCHES=100
EXTRA=()
LABEL=appkit
while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) SIZES+=("$2"); shift 2 ;;
    --switches) SWITCHES="$2"; shift 2 ;;
    --swiftui-table) EXTRA+=(-WWEntryListImplementation swiftui); LABEL=swiftui; shift ;;
    *) echo "usage: scripts/measure-sidebar-switches.sh [--size WxH ...] [--switches N] [--swiftui-table]" >&2; exit 2 ;;
  esac
done
[[ ${#SIZES[@]} -eq 0 ]] && SIZES=(1000x600)
[[ -x "$APP" ]] || { echo "error: build the Debug app first (scripts/build.sh)" >&2; exit 2; }

OUT="$ROOT/.build/sidebar-switches"
mkdir -p "$OUT"
for size in "${SIZES[@]}"; do
  start="$(date '+%Y-%m-%d %H:%M:%S')"
  "$APP" -WWUITestHooks YES -WWUITestResetPreferences YES -WWUITestLibraryFixture lib100 \
    -WWMeasureSidebarSwitches "$SWITCHES" -WWMeasureWindowSize "$size" ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then echo "error: timed out; stopping $pid" >&2; kill "$pid"; exit 1; fi
  sleep 2
  log show --start "$start" --style compact \
    --predicate 'subsystem == "com.brandonmartinez.wavewrangler" AND category == "Benchmark"' > "$OUT/$LABEL-$size.log"
  echo "$LABEL $size: $(grep -c 'WWBENCH step' "$OUT/$LABEL-$size.log") switches"
  grep -o 'WWBENCH summary.*' "$OUT/$LABEL-$size.log" || { echo "error: no summary logged" >&2; exit 1; }
done
