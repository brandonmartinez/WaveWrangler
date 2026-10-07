# WW-220 episode-switch responsiveness: gate still open

The M2 exit gate is **event-to-commit nearest-rank p95 <100 ms over 100 episode switches**. The unchanged `ResponsivenessUITests.testInteractions` and `docs/m1/evidence/ww-007/collect_timings.py` supply the measurements below. All GUI runs used synthetic `lib100files` data on Macsimus.local (Mac mini, macOS 27.0.1) under its FIFO GUI lock. Load is the host's 1-minute load average before and after each run; the candidate runs checked for at least 60 seconds of idle time before starting.

| Revision | Change | Load before -> after | Episode samples | p95 (ms) | Max (ms) | Gate |
| --- | --- | --- | ---: | ---: | ---: | --- |
| `348af45` | M1 exit main baseline | 3.69 -> 4.94 | 100 | 107.793 | 119.962 | Fail |
| `2cd2194` | Avoid repeated Setup window work/initial column refits | 5.09 -> 4.13 | 100 | 110.033 | 116.476 | Fail |
| `2af29ff` | Lazy Library menu selection; build only selected rows | 4.48 -> 8.11 | 100 | 113.854 | 123.581 | Fail |
| `331df72` | Also keep selected sidebar row's SwiftUI view identity stable | 5.17 -> 5.16 | 100 | 103.384 | 115.249 | **Fail** |

## New timebox: M1 exit versus main

The coordinator approved three additional mini GUI rounds to establish whether the post-M1 change is a reproducible code regression. `git diff --stat 21104e9 348af45 -- WaveWrangler WaveWrangler.xcodeproj Packages/WaveWranglerKit/Sources/WWSources Packages/WaveWranglerKit/Package.swift` shows only the DEBUG evaluator-start test hook in `SourceAvailabilityMonitor.swift` and additional package products; the app UI and XCUITest sources do not differ. Separate Debug build-for-testing products were built from archived source trees, without changing this worktree's branch. Round 1 ran the unchanged 100-sample test A,B,A,B on the same mini under one GUI lock. Each recorded start had at least 60 seconds of idle time and a 1-minute load below 6.

| Round 1 label | Source SHA | Mini load before -> after | Episode n | Event p95 / max (ms) | Handler-to-commit p95 / max (ms) | Gate |
| --- | --- | --- | ---: | --- | --- | --- |
| A1 (M1 exit) | `21104e9` | 4.48 -> 2.92 | 100 | 112.841 / 125.031 | 96.486 / 120.235 | Fail |
| B1 (main) | `348af45` | 2.84 -> 4.38 | 100 | 116.517 / 147.714 | 99.270 / 138.821 | Fail |
| A2 (M1 exit) | `21104e9` | 4.55 -> 4.28 | 100 | 114.755 / 132.523 | 96.061 / 119.752 | Fail |
| B2 (main) | `348af45` | 4.19 -> 3.39 | 100 | 114.688 / 120.626 | 96.117 / 113.751 | Fail |

**Both revisions fail in both quiet runs.** This does not establish that the small post-exit diff caused the gate miss; host/environment or run-condition drift is more likely. The M1 exit record (`docs/planning/milestone-exits/m1.md` §4) reports 5/5 `ResponsivenessUITests` passing at `21104e9`, not a 100-sample p95 for that run. Its xcresult/JSON was not found under the mini's `~/ww-uitest-runs` directory. Round 1 raw artifacts: `~/ww-uitest-runs/ww220-ab-21104e9-348af45/` (`A1`, `B1`, `A2`, `B2` logs, JSON, JSONL, xcresults and `ab-load.log`).

Round 2 compared `348af45` with one targeted SwiftUI-outline experiment: `EpisodeSidebarRow.equatable()` with explicit selection/rename snapshots, intended to avoid rebuilding the other rows' hosting content on selection change. It passed the Debug build but **worsened** the gate in both B,C,B,C comparisons, so the experiment was removed after measurement. Starts were idle at least 60 seconds, with 1-minute load below 6.

| Round 2 label | Source SHA | Mini load before -> after | Episode n | Event p95 / max (ms) | Handler-to-commit p95 / max (ms) | Gate |
| --- | --- | --- | ---: | --- | --- | --- |
| B3 (main) | `348af45` | 4.13 -> 3.73 | 100 | 112.625 / 118.471 | 95.964 / 100.437 | Fail |
| C1 (outline experiment) | `7c67443` | 4.09 -> 3.90 | 100 | 118.290 / 129.203 | 98.579 / 113.271 | Fail |
| B4 (main) | `348af45` | 3.11 -> 5.74 | 100 | 113.263 / 120.252 | 98.132 / 109.947 | Fail |
| C2 (outline experiment) | `7c67443` | 3.66 -> 3.09 | 100 | 117.801 / 131.749 | 97.474 / 114.372 | Fail |

Round 2 raw artifacts are alongside round 1 (`B3`, `C1`, `B4`, `C2` logs, JSON, JSONL, xcresults and `bc-load.log`).

Round 3 compared main with the restored stable-foreground candidate (the current branch's app code matches `331df72`). All starts again had at least 60 seconds of idle time and 1-minute load below 6.

| Round 3 label | Source SHA | Mini load before -> after | Episode n | Event p95 / max (ms) | Handler-to-commit p95 / max (ms) | Gate |
| --- | --- | --- | ---: | --- | --- | --- |
| B5 (main) | `348af45` | 3.79 -> 7.20 | 100 | 117.459 / 121.369 | 98.290 / 101.345 | Fail |
| D1 (stable foreground) | `331df72` | 5.21 -> 4.87 | 100 | 119.455 / 133.569 | 102.452 / 120.110 | Fail |
| B6 (main) | `348af45` | 2.98 -> 6.59 | 100 | 116.352 / 122.837 | 103.601 / 117.607 | Fail |
| D2 (stable foreground) | `331df72` | 4.56 -> 6.47 | 100 | 118.610 / 127.456 | 103.104 / 117.400 | Fail |

The stable-foreground candidate **does not improve the gate** in this paired run. The earlier unpaired 103.384 ms result is retained above, but cannot establish a repeatable win. Round 3 artifacts (`B5`, `D1`, `B6`, `D2` logs, JSON, JSONL, xcresults and `bd-load.log`) are under the same mini run directory as rounds 1 and 2. No M1-to-main code regression has been shown; the 100-sample gate also fails twice on the historical M1 exit tree. **Recommendation: keep #220 open and the PR draft; investigate host/run-condition drift before another code change or seek a user decision on the unchanged gate.**

The Setup-only attempt was reverted in `2af29ff`. The Library optimization remains: `CommandRouter` now constructs selection only for actions that require it, and `LibraryPresentation` filters IDs before row construction/sorting without caching potentially stale status. `LibraryPresentationTests` covers all four sidebar kinds, order, status and empty selection. The stable-foreground change replaces the conditional selected-row view hierarchy with one modifier; selected, focused rows remain explicitly white, while other rows inherit the system foreground. The first four rows of the earlier table were **not** load-matched controlled A/B trials; the controlled trials above supersede any inference of improvement.

The 40-second Time Profiler trace on `2cd2194` sampled 31,956 main-thread CPU stacks during the interaction phase. `LibraryWindowState.selectedRows` occurred in 1,137 samples overall, often under `CommandRouter.validateMenuItem` as XCUITest queried menu accessibility; that work did **not** account for the measured switch interval. Aligning the trace's wall-clock start with the app's per-switch timestamps found 7,440 main-thread samples inside measured event-to-commit intervals, including 5,364 in `CA::Transaction::commit()`. SwiftUI outline-list selection, hosting-view changes, layout and accessibility updates also appear in these intervals. A profiler hot spot alone was not proof of a gate fix.

The unchanged **native Library sidebar** script (`scripts/measure-sidebar-switches.sh`, direct Debug app launch, 100 switches) measured p95 **48.0 ms**, max **99.0 ms** at `348af45` on Macsimus.local, load **3.92 -> 4.02**. In round 3 on that same mini (actual window 1000x548): main `348af45`, load **4.21 -> 4.74**, n=100 p95 **47.2 ms**, max **99.5 ms**; candidate `331df72`, load **3.31 -> 3.15**, n=100 p95 **47.5 ms**, max **95.4 ms**. Native stdout, unified logs and load records are in `native-B.*`, `native-D.*`, `native-load.log`. This is a **Library selection** benchmark, *not* the episode-switch gate. Historical M1 evidence reported about 95 ms for episode switching at `10eb4b8`; that revision is on a divergent M1 branch and is not a paired measurement against this run.

The full `scripts/test.sh` passed on Macatron.local at restored code head `fce2be8` (load **12.20 -> 13.44**); macOS 26 CI also passed on that head. Focused `LibraryPresentationTests` passed on Macatron.local at `2af29ff` (load not captured). The final mini UI run on `331df72` (load **2.24 -> 6.08**) reported **20 passed, 2 failed, 0 skipped** in its xcresult:

- `ResponsivenessUITests` **5/5** (calibration sample count 5, not the 100-sample gate); `LibraryWorkspaceUITests` **8/8**; `LibraryManagementUITests` **1/1**; `SelectionContrastUITests` **1/1**. Selected accent rows retained opaque white text, p75 contrast 5.37:1 light and 4.76:1 dark; unfocused selections and high-contrast appearance variants passed (the system Increase Contrast setting was false).
- `CoreTasksKeyboardUITests` **5/6**: T16 failed two assertions under the existing #66 deferral: the conflict sheet lacks "Save Mine as a Copy…" and the save refusal says "Conflict: Not saved. Couldn't save…" instead of the expected status. The M1 exit record describes the refused save and "Not saved" status; the other five tests passed.
- `EpisodeSetupUITests.testColumnsStayStableAcrossRepeatedZoom` **failed** its final-cycle/early-range assertion: Status x offsets `[925.0, 923.5, 964.0, 960.5, 964.0, 964.0, 964.0, 964.0, 964.0, 895.0]`. All ten cycles retained a visible Status column and the full range was 69 pt (<100 pt), but the last offset was 8.5 pt outside the early-range ±20 pt bound. Whether this is layout variability or a product regression is **unresolved**, not counted as a pass. Full output and xcresult: `final-regression.log`, `final-regression.xcresult`, `final-regression-load.log` in the round 3 directory.

The earlier three unsuccessful mini trials exhausted the first timebox; all three new GUI rounds are now complete. The PR remains draft with `Refs #220`, not `Closes #220`, and should not merge on this evidence.

Raw mini artifacts (outside the repository): `~/ww-uitest-runs/ww220-perf-baseline/` (native Library baseline), `~/ww-uitest-runs/ww220-perf-2cd2194/` (including `episode-switch.trace` and `time-profile.xml`), `~/ww-uitest-runs/ww220-perf-2af29ff/`, and `~/ww-uitest-runs/ww220-perf-331df72/` (each candidate's `interactions-100.log`, `.json`, `.raw.jsonl`, `.xcresult`, and load record). The mini lock was released and no processes launched from the final run's Products directory remain.
