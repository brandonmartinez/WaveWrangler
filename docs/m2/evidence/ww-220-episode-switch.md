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

Round 2 raw artifacts are alongside round 1 (`B3`, `C1`, `B4`, `C2` logs, JSON, JSONL, xcresults and `bc-load.log`). The remaining GUI round compares the restored stable-foreground candidate with main and checks the affected UI contracts.

The Setup-only attempt was reverted in `2af29ff`. The Library optimization remains: `CommandRouter` now constructs selection only for actions that require it, and `LibraryPresentation` filters IDs before row construction/sorting without caching potentially stale status. `LibraryPresentationTests` covers all four sidebar kinds, order, status and empty selection. The final change replaces the conditional selected-row view hierarchy with one stable modifier; selected, focused rows remain explicitly white, while other rows inherit the system foreground. Its measured improvement relative to `2af29ff` is encouraging but **not sufficient to establish the root cause or pass the gate**. These runs were not load-matched controlled A/B trials.

The 40-second Time Profiler trace on `2cd2194` sampled 31,956 main-thread CPU stacks during the interaction phase. `LibraryWindowState.selectedRows` occurred in 1,137 samples overall, often under `CommandRouter.validateMenuItem` as XCUITest queried menu accessibility; that work did **not** account for the measured switch interval. Aligning the trace's wall-clock start with the app's per-switch timestamps found 7,440 main-thread samples inside measured event-to-commit intervals, including 5,364 in `CA::Transaction::commit()`. SwiftUI outline-list selection, hosting-view changes, layout and accessibility updates also appear in these intervals. Reducing row hierarchy churn improved p95, but the remaining tail needs investigation before claiming a complete fix.

The unchanged **native Library sidebar** script (`scripts/measure-sidebar-switches.sh`, direct Debug app launch, 100 switches, 1000x600) measured p95 **48.0 ms**, max **99.0 ms** at `348af45` on Macsimus.local, load **3.92 -> 4.02**. It is *not* an episode-switch measurement. A same-host after run was **not performed**. Historical M1 evidence reported about 95 ms for episode switching at `10eb4b8`; that revision is on a divergent M1 branch and is not a paired measurement against this run.

At `331df72`, `scripts/test.sh` passed on Macatron.local (load not captured for this headless run), and CI **Build and test (macOS 26)** passed. Focused `LibraryPresentationTests` passed at `2af29ff` on Macatron.local (load not captured). The earlier three unsuccessful mini GUI trials exhausted the first timebox; the coordinator then authorized a new three-round timebox, of which two rounds are recorded above. The full `ResponsivenessUITests`, `LibraryWorkspaceUITests`, `LibraryManagementUITests`, `CoreTasksKeyboardUITests`, Setup zoom/column and `SelectionContrastUITests` have **not** been run on this head, nor has the native after benchmark. The PR remains draft with `Refs #220`, not `Closes #220`.

Raw mini artifacts (outside the repository): `~/ww-uitest-runs/ww220-perf-baseline/` (native Library baseline), `~/ww-uitest-runs/ww220-perf-2cd2194/` (including `episode-switch.trace` and `time-profile.xml`), `~/ww-uitest-runs/ww220-perf-2af29ff/`, and `~/ww-uitest-runs/ww220-perf-331df72/` (each candidate's `interactions-100.log`, `.json`, `.raw.jsonl`, `.xcresult`, and load record). The mini lock was released and no processes launched from the final run's Products directory remain.
