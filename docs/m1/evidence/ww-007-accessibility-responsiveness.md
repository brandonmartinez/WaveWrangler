# WW-007 integrated accessibility and responsiveness acceptance evidence

**Owner:** Design · **Refs:** [WW-007 (#8)](https://github.com/brandonmartinez/WaveWrangler/issues/8), [WW-011 (#2)](https://github.com/brandonmartinez/WaveWrangler/issues/2), [WW-012 (#9)](https://github.com/brandonmartinez/WaveWrangler/issues/9), [WW-013 (#12)](https://github.com/brandonmartinez/WaveWrangler/issues/12), [#59](https://github.com/brandonmartinez/WaveWrangler/issues/59) · **Spec executed:** [accessibility-acceptance.md](../design/accessibility-acceptance.md) (T01–T30, A-01…A-08, C01…C08)

Results use only **Pass**, **Fail** (with issue), **Blocked** (with reason) and **Not run** (with reason). Missing evidence is never Pass. XCUITest results never stand in for VoiceOver or Full Keyboard Access results. Each holdout execution is reported exactly as executed. Later executions are labelled as re-executions and disclose what changed.

## 0. Summary

| Area | Result |
| --- | --- |
| **SCALE-001 native** (WW-007 timing) | **Holdout `cb42138`: Fail.** First open p95 1.048 s ([#105](https://github.com/brandonmartinez/WaveWrangler/issues/105)) and sidebar selection p95 165 ms ([#106](https://github.com/brandonmartinez/WaveWrangler/issues/106)); every other stratum passed. **Post-fix re-execution `10eb4b8` (main `251d122` with #107/#108 + this branch): Pass.** Every gate passes: first open p95 461 ms, sidebar p95 52 ms; episode switch p95 95 ms with 4 of 100 samples over 100 ms. |
| DUR-026 native lifecycle ×20 | **Pass** (18 Pass, 0 Fail, 2 Not run: Dock › Quit, a tool limit and a user-manual item). Executed on `241396a` (18-core host). **Re-executed on the Mac mini (macOS 27.0.1, M2 Pro) at `4a109aa` (main `6e35da2`): 18 Pass, 0 Fail, 2 Not run, the same routes.** A first attempt on `08f62ee` was **aborted by a harness defect** at scenario 1 (raw record committed). |
| REF-020 sandboxed grant ×20 | **Fail (holdout).** Holdout `08f62ee`: 16 executed, 4 not executed; 12 Pass, 4 Fail, all from harness defects. **Labelled re-execution on the Mac mini (macOS 27.0.1, M2 Pro) at `550506d` (main `6e35da2`, launch-once harness): 20 executed, 20 Pass, 0 Fail.** Earlier re-executions were aborted or harness-invalid (§2.3). Re-executions are disclosed and don't replace the holdout. Raw records committed. |
| A11Y-001 keyboard full suite | **Fail.** 1/1 executed on `241396a`: 45 tests, 36 Pass, 6 Fail, 3 skipped for VO. CoreTasks re-run on the Mac mini (macOS 27.0.1, M2 Pro) with main `6e35da2` (§4):
- **Pass:** T01, T02/T03/T15, T24.
- **Fail:** T16 on [#66](https://github.com/brandonmartinez/WaveWrangler/issues/66) and [#125](https://github.com/brandonmartinez/WaveWrangler/issues/125). It is safe and not a dead end: Save As from the conflicted state passes.
- **Fail:** T17/T20 on [#126](https://github.com/brandonmartinez/WaveWrangler/issues/126) (alert contrast 2.85–2.95).

Since fixed on main: #104 (#112), #109/#110 (#113). |
| A11Y-002 VoiceOver | **Blocked** (0/1). Attempted on the Mac mini (macOS 27.0.1, M2 Pro) at `475adf3` (§10.3): VoiceOver ran, but XCTest timed out snapshotting VoiceOver's caption panel at the first step of all 3 walks, so **no announcement was captured** and none is claimed. **VoiceOver listening is a user-manual exit item** (checklist §5.1). |
| A11Y-003 visual | **Fail** (1/1 executed; in-app overrides on the 18-core host, plus re-measurement and system settings on the Mac mini (macOS 27.0.1, M2 Pro) at `475adf3`, §10).
- C03 200% Library: Fail on `241396a` ([#109](https://github.com/brandonmartinez/WaveWrangler/issues/109), since fixed by #113; `testLibraryAt200PercentTextStaysInsideTheWindow` passes on the mini with main's placement).
- **C03 Setup: Pass** on the re-measurement (`475adf3`, §10.1). Setup aqua and darkAqua 200% have no unwaived findings. The `479eb9e` "Access denied" 1.77 did not reproduce; it predates #112. The remaining 100% findings are classified with crops.
- C06: Pass (captured surfaces).
- **C07 light/dark: Pass** on the re-measurement (`475adf3`, §10.1). None of the `479eb9e` candidates reproduced. Every remaining finding is a measured artefact with a crop (§10.1).
- **C04 Increase Contrast (system): Fail** ([#138](https://github.com/brandonmartinez/WaveWrangler/issues/138)). The selected Library sidebar row's text is 2.33:1 on the dark accent fill. One edge-slice finding is unresolved (§10.2).
- **C05 Reduce Motion (system): Not run.** The setting was applied and observed by the test runner, and the flows completed, but motion isn't observable in static captures.
- **Larger text (system): Not run.** `FontSizeCategory` doesn't change AppKit's fonts (body stayed 13 pt). In-app 200% is the tested path. |
| A11Y-004 static audit | **Pass** (1/1 executed: 0 flags across 132 controls). It's heuristic: it missed the merged sidebar "+" button the GUI run found ([#110](https://github.com/brandonmartinez/WaveWrangler/issues/110)). |
| #59 | Sidebar and inspector findings are **measured audit artefacts** (15.7–18.1:1). The entry-table blur under a Library message bar was a **real failure**; #113 brought it back on main (row 1: 4 glyph pixels). **Fixed in this PR with option (a) (coordinator decision):** the bar sits in the content column. On the Mac mini (macOS 27.0.1, M2 Pro) at `550506d`, row 1 has 1,725 px at 15.91:1 (light) and 2,086 px at 12.39:1 (dark), and ContrastEvidence now **asserts** it. Every Library suite passes with measured waivers in place of the former blanket "#59 tracked" waivers (§7). |
| P0s | **None found.** |

## 1. Run record

| Item | Value |
| --- | --- |
| Host (claimed, **not** the macOS 26 / 16 GB reference, which is WW-052) | Mac17,14, Apple M5 Max (18 cores), 128 GiB, macOS 27.0.1, Xcode 27.0 |
| Revisions (all contain the freeze merge `2fcf4d7`; clean worktree at run time) | `8aec54b` calibration · `c2edf8c` verification · `cb42138` (tree `aa4f626a…`) SCALE-001 holdout · `08f62ee` (tree `8032173c…`) first DUR-026/REF-020 executions · `241396a` (tree `9ca340b1…`, main `251d122` merged) DUR-026 ×20, REF-020 re-execution, full suite · `10eb4b8` (tree `68bce2a5…`) SCALE-001 post-fix re-execution and #86 re-verification |
| Build | `scripts/build.sh` (Debug, ad-hoc signed, `-jobs 4`, DerivedData in the worktree): **BUILD SUCCEEDED** on every revision |
| Package and unit tests | `scripts/test.sh`: all `swift test` suites passed (60, 145, 70, 55 and 41 tests), the serialized timing passes passed, and `WaveWranglerTests` 7/7 passed. On one run xcodebuild then reported "test runner hung before establishing connection" after the 7 tests had passed. That happened while XCUITest automation mode was unauthorized (§1.2), not on a failing test. |
| UI tests | `scripts/test.sh --ui [-only-testing:…]`, Debug, serial, under the coordinator GUI lock |
| Fixtures | Synthetic only: F-LIB100 (`lib100` in-memory; `lib100files` = 97 generated show files with 1,000 metadata-only references), probe-generated `.wwshow` files, the `WW_SETUP_ENGINE=fixture-states` scripted engine, and generated placeholder `.wav` files in the runner's temp directory. No user media, paths or names. |

### 1.1 Instrumentation

- `WaveWrangler/Support/Responsiveness.swift` measures each interval from the input event's own timestamp (`NSEvent.timestamp`, so queueing counts) to the end of the main run-loop pass that committed the change. That end point is a one-shot `beforeWaiting` observer at the highest order, which runs after AppKit's display cycle and Core Animation's commit. Final frame composition (≤ 1 refresh) isn't included.
- Intervals are emitted as signposts. In Debug runs with `-WWUITestTimingLog YES` they're also written as `WWTIMING` log lines. #107 and #108 reuse the same harness. The persistence lane confirmed on 30 samples that the start event is the real Return keyDown.
- The UI-test runner is **sandboxed**: it can't read the unified log, run `xctrace`, reach the Dock or run `git`. Tests print `[phase]` markers, and [`ww-007/collect_timings.py`](ww-007/collect_timings.py) assigns the app's lines to phases. It reports nearest-rank p95 (`ceil(0.95n)`) and max.

### 1.2 Interruption: XCUITest automation mode

From about 08:37 to 09:45 EDT every `--ui` run failed with "Timed out while enabling automation mode", because the device required user authentication. The user re-authorized it, and every later run used it normally.

## 2. Frozen-registry families (m1-freeze-1)

| Family | Frozen | Achieved | Result |
| --- | ---: | ---: | --- |
| M1-SCALE-001 native (first-open / warm / interactions) | 100 / 100 / 400 | Holdout: 100 executed (99 timed; one app log line wasn't persisted) / 100 / 403. Post-fix: 100 / 100 / 402. | §2.1 |
| M1-DUR-026 native lifecycle | 20 | 20 executed (`241396a`): 18 Pass, 2 Not run. The first attempt (`08f62ee`) aborted by a harness defect. | §2.2 |
| M1-REF-020 sandboxed grant | 20 | 16 executed, 4 not executed (`08f62ee`) | **Fail**: 12 Pass, 4 Fail, all harness defects (§2.3) |
| M1-A11Y-001 keyboard full suite | 1 | 1 | **Fail** (§4) |
| M1-A11Y-002 VoiceOver full suite | 1 | **0** | **Blocked** (§5) |
| M1-A11Y-003 visual full suite | 1 | 1 (in-app overrides; system settings on the Mac mini, §10) | **Fail**: C04 [#138](https://github.com/brandonmartinez/WaveWrangler/issues/138); C05 and larger text Not run (§10) |
| M1-A11Y-004 static audit | 1 | 1 | **Pass** (§3) |

No count was lowered and nothing was relabelled.

### 2.1 SCALE-001 native timing

Raw samples: [`scale001-native-raw.jsonl`](ww-007/scale001-native-raw.jsonl) (holdout) and [`scale001-native-postfix-raw.jsonl`](ww-007/scale001-native-postfix-raw.jsonl) (post-fix). Summaries are in the matching `*-summary.json` files. All intervals finished on the main thread. Debug build. The gates are provisional and apply to the claimed host only.

| Stratum | Gate | Holdout `cb42138`: n · p95 · max | Post-fix re-execution `10eb4b8`: n · p95 · max |
| --- | --- | --- | --- |
| Launch → library ready (process start → first commit with 100 entries) | < 1 s | 100 · 588 ms · 640 ms ✅ | 100 · 612 ms · 659 ms ✅ |
| **First open**, fresh process (Return → show-window commit) | < 1 s | 99 · **1,048 ms ❌** · 1,116 ms | 100 · **461 ms ✅** · 530 ms |
| **Warm reopen**, same process | < 1 s | 100 · 247 ms ✅ · 258 ms | 100 · 224 ms ✅ · 230 ms |
| **Library sidebar selection** | < 100 ms | 103 · **165 ms ❌** · 177 ms | 103 · **52 ms ✅** · 67 ms |
| Collection move (library edit) | < 100 ms | 100 · 20 ms ✅ · 43 ms | 100 · 17 ms ✅ · 29 ms |
| Episode switch | < 100 ms | 100 · 81 ms ✅ · 93 ms | 100 · **95 ms ✅** · **136 ms** (4 over 100 ms) |
| Episode title edit (per keystroke) | < 100 ms | 100 · 28 ms ✅ · 32 ms | 99 · 25 ms ✅ · 29 ms |
| **All interactions pooled** | < 100 ms | 403 · 77 ms ✅ · 177 ms | 402 · 86 ms ✅ · 136 ms |

- **Holdout first open** was bimodal: about 80% of samples took 0.19–0.6 s and about 20% took 0.91–1.12 s.
  - #107 moved evidence and library work past the first frame; the slow mode is gone in the post-fix run.
  - #108 replaced the Library `Table` with an AppKit outline, so switching to "Shows" went from 165–177 ms to ≤ 67 ms.
- **Episode switch** is now the interaction closest to the gate: p95 95 ms, max 136 ms after #55's Setup content. Watch it in WW-052.
- `XCTApplicationLaunchMetric` (launch until responsive, 9 iterations, holdout tree): average 0.582 s, max 0.636 s.
- **Main-thread file I/O:**
  - The calibration File Activity trace on `8aec54b` ([`calibration-8aec54b-main-thread-io.json`](ww-007/calibration-8aec54b-main-thread-io.json)) recorded 3,176 main-thread file syscalls over about 35 s, 80 ms in total:
    - document read/write including autosave `fsync`: about 4.9 ms;
    - recovery store: about 17.6 ms;
    - the rest: system lookups.
  - **Document and recovery I/O does run on the main thread** (NSDocument synchronous read/write by design). It's small, but not zero.
  - Source/provider I/O after #55 wasn't traced: the holdout `xctrace --attach WaveWrangler` was ambiguous because another lane's process was running. **Not run.**

### 2.2 DUR-026 native lifecycle

- Raw per-scenario lines and XCTest errors for every DUR-026 and REF-020 execution, including the aborted ones, are in [`ww-007/raw-dur026-ref020-executions.jsonl`](ww-007/raw-dur026-ref020-executions.jsonl). Aborted runs never reached their end-of-test JSON record.
- **First attempt (`08f62ee`): aborted by a harness defect at scenario 1.** The window was looked up by the document's name, but the show-window title now changes during edits. Corrected to look it up by identifier in `cc41261`.
- **Execution on `241396a`:** 20 scenarios cycling through 9 routes ([`runs-evidence.jsonl`](ww-007/runs-evidence.jsonl), `dur026-native-lifecycle`).

| Route | Scenarios | Result |
| --- | --- | --- |
| Close (⌘W), OFF dirty: Cancel keeps work, then Save writes | #1, #10, #19 | Pass ×3 |
| ⌘Q, OFF dirty: Cancel keeps app, then Don't Save quits without writing | #2, #11, #20 | Pass ×3 |
| App menu › Quit, OFF dirty: Save writes and quits | #3, #12 | Pass ×2 |
| Dock › Quit | #4, #13 | **Not run ×2**. The sandboxed runner can't read the Dock's AX tree or send Apple events, and background computer-use can't open the Dock menu. User-manual item. |
| AS01: edit while ON, OFF within the delay → nothing written, Close prompts | #5, #14 | Pass ×2 |
| AS05: OFF dirty Close › Don't Save → closes, disk unchanged | #6, #15 | Pass ×2 |
| Save As… panel cancelled → nothing written, still dirty | #7, #16 | Pass ×2 |
| Revert To › Last Saved Version → edits discarded, focused field shows the disk value (#86) | #8, #17 | Pass ×2 |
| Relaunch with an edit checkpoint → "Restore Unsaved Changes" restores; status "Edited…", never Saved (#84/#95) | #9, #18 | Pass ×2 |

**Re-execution on the Mac mini (macOS 27.0.1, M2 Pro), `4a109aa` (main `6e35da2`):**
- 20 scenarios: **18 Pass, 0 Fail, 2 Not run** (Dock, #4 and #13). Every other route passed, including Revert (#8, #17) and relaunch-with-checkpoint (#9, #18).
- Raw records: [`raw-mini-6e35da2-runs.jsonl`](ww-007/raw-mini-6e35da2-runs.jsonl) (`runC`).
- Side effect found: the checkpoint from #18 persisted in the isolated UI-test storage and covered later CoreTasks windows. CoreTasks now starts each task with fresh storage (`94176b5`).

`241396a` had my **first** #86 fix. The corrected fix (`10eb4b8`) was re-verified on routes 8 and 9 plus all 10 `DocumentLifecycleUITests`: **all pass**.

### 2.3 REF-020 sandboxed grant / relaunch / regrant / relink

One cycle is 4 GUI scenarios on fresh synthetic files:
1. **Grant**: File › Import Sources… → sandboxed panel (powerbox) → folder → Import Review → Import.
2. **Relaunch**: the bookmark resolves.
3. **Regrant**: with no device-local record (`-WWUITestResetSourceAccess YES`), Source › Grant Access… → panel → identity comparison.
4. **Relink**: the harness moves a file, then Source › Relink Source… → panel → comparison → confirm.

Every scenario checks SHA-256 and mtime of every source.

| Execution | Scenarios | Result |
| --- | --- | --- |
| **First execution, `08f62ee`** | 16 executed, 4 not executed | Cycles 1–4: grant 4/4, relaunch 4/4, regrant 2/4, relink 2/4, so **12 Pass, 4 Fail**. All 4 failures were **harness row-selection defects**: the row click didn't select, so Grant Access and Relink stayed disabled. Cycle 5 **aborted** on a harness defect (an unguarded Import Review read after the panel didn't confirm), so its 4 scenarios weren't executed. |
| Post-harness-correction re-execution, `241396a` (fixes `cc41261`, `74c13d9`) | 6 recorded: 3 Pass, 3 Fail | Cycle 1: grant, relaunch and relink pass; regrant failed because the identity sheet didn't appear (panel timing). Cycle 2: the Import Review didn't appear (panel timing), then the run aborted. **Disclosed; it doesn't replace the first execution.** |
| Full-suite cycle, `241396a` | 4 | 4/4 Pass |
| Re-execution, Mac mini (macOS 27.0.1, M2 Pro), `4a109aa` (main `6e35da2`) | **harness-invalid, stopped** | Cycle 1 grant failed with "imported rows present: [:]". Since #112 the Setup Name cell's AX value carries the hidden columns ("epoch none, channels …"), and the harness read the value before the label. Fixed in `e3984d8` (match label or value). No scenario result is claimed from this attempt. |
| Re-execution, Mac mini (macOS 27.0.1, M2 Pro), `9e994b1` (main `6e35da2`) | 3 recorded: **3 Pass**, then aborted | Cycle 1: grant, relaunch and regrant Pass (sources Ready; the regranted source Ready; zero source writes). Relink: after ⌘Q and the harness moving a source, the relaunch opened the document but **no window appeared within 10 s**. The AX tree had the menu bar and no windows, not even Library. The test threw and aborted. **Diagnosed as a harness defect, not a product bug.** launchd and runningboard logs show every `app.launch()` + `app.open(document)` pair spawned two processes (e.g. 92503/92506). XCTest stayed bound to 92503, which had no windows (`-WWUITestHooks` with no library fixture suppresses the Library window) and no document activity. 92506 opened `Grant 0.wwshow` 0.45 s after spawning (file-coordination read 15:49:59.793, isolated UI-test storage). Fix: `XCUIApplication.launchOnce(opening:)` (`f1c8f45`/`972acad`). |
| **Labelled re-execution, Mac mini (macOS 27.0.1, M2 Pro), `550506d` (tree `287fbc5`, main `6e35da2`, launch-once)** | **20 executed: 20 Pass, 0 Fail** | 5 cycles × grant, relaunch, regrant, relink, all Pass (595 s). Zero source writes. Statuses honest: regranted Ready; "Needs permission; location unknown; download state unknown; file details not checked" for the source without a record; "Moved" after the harness moved a file. Each show window opened in ≈ 2.0 s, including launch. Raw records: [`raw-mini-550506d-runs.jsonl`](ww-007/raw-mini-550506d-runs.jsonl) (`runH`). |

**Raw records:** [`ww-007/raw-dur026-ref020-executions.jsonl`](ww-007/raw-dur026-ref020-executions.jsonl) has every `[evidence]` line, test-case result and XCTest error, from both the first execution and the re-execution.

**Product state in every executed scenario:**
- Sources stayed byte- and mtime-unchanged.
- Statuses were honest: "Needs permission; location unknown; download state unknown; file details not checked" (never "Not found"); "Moved" after the harness moved a file.
- Comparison sheets read "File details match. WaveWrangler compared file details, not audio." or "Some file details are different: file id."

**No product failure was observed.** Driving the out-of-process powerbox panel by keystrokes is the reliability limit of this harness.

## 3. Automated structural checks

| ID | Check | Result | Evidence |
| --- | --- | --- | --- |
| A-01 | Catalog symbols resolve (this host) | Pass | `PresentationTests.everyCatalogSymbolResolves`; `SourceStatusTests` (A-01) |
| A-02 | Wording catalog | Pass | `exactWordingForKeyStates`, `settingsCaptionsMatchSpecification` |
| A-03 | Summary priority / never "Offline" | Pass | `SourceStatusTests` (A-03), `everyStateHasTextAndNeverSaysOffline` |
| A-04 | Honest save state | Pass | `onlyCoherentSaveSaysSaved`, `onlyD1ClearsDirtyAndEditedSuffix`, `closeDecisionsFollowStateTable` |
| A-05 | Undo names | Pass | `SetupEditCommandTests` (A-05) |
| A-06 | Shortcut register / no duplicates | Pass | `shortcutsAreUniqueAndCustomRegisterMatchesSpecification` |
| A-07 | Fresh defaults | Pass | `freshPreferencesUseProductDefaults` |
| A-08 | Downloads Off ⇒ zero requests | Mac-owned | Covered by the WWSources / WWEpisodeSetup engine tests in `scripts/test.sh` (passed). Not independently re-checked by Design. |
| **A11Y-004** | Static audit: [`ww-007/static_audit.py`](ww-007/static_audit.py), result [`a11y004-static-audit.json`](ww-007/a11y004-static-audit.json) | **0 flags.** 132 controls, 78 identifiers, 54 explicit labels, 7 hints, 18 help tags. No unlabelled icon-only button, no context-menu item without a menu-bar equivalent, no colour-only status candidate, no drag-only interaction. | Heuristic and source level only. It missed the merged sidebar "+" button that the GUI run found ([#110](https://github.com/brandonmartinez/WaveWrangler/issues/110)). |

## 4. A11Y-001 full suite and core task suite T01–T30

**Full XCUITest suite (`scripts/test.sh --ui`, `241396a`): 45 tests — 36 pass, 6 fail, 3 skipped.**

**Failures:**
- `CoreTasks…testT02T03T15…`: the audit flagged a Role placeholder clipped at the default window size (pixel ratio 1.06:1, scrolled out of view) → [#104](https://github.com/brandonmartinez/WaveWrangler/issues/104).
- `testT16ConflictNeverOverwrites`: Design D6 isn't implemented → [#66](https://github.com/brandonmartinez/WaveWrangler/issues/66) (M2); the data invariant holds (see T16).
- `DocumentLifecycleUITests.testRelaunchAfterNewerSaveOffersOnlySeparateCopy` and `testTwoCrashedSessionsAreOfferedOneAfterAnother`: **caused by my first #86 fix**, which also replaced a focused draft during live typing. Attribution: with main's `Inspectors.swift` both pass. The corrected fix (`10eb4b8`) discards a focused draft only when the model change came from elsewhere. Re-verified: all 10 `DocumentLifecycleUITests` pass.
- `LibraryManagementUITests` (WW-013): the sidebar "+" button → [#110](https://github.com/brandonmartinez/WaveWrangler/issues/110). Every other WW-013 step passed.
- `LibraryWorkspaceUITests.testSettingsDefaultsTogglesAndTextSize`: the lane audit at 200% flagged clipped message-bar text → [#109](https://github.com/brandonmartinez/WaveWrangler/issues/109).

**Skipped:** `VoiceOverWalkUITests` ×3 (VoiceOver not running; §5).

**Passing suites include:**
- all `EpisodeSetupUITests` (T07–T13, T18, T29, Speakers height);
- `LibraryWorkspaceUITests` T01–T06, T22, T24 and relaunch reopen;
- 8/10 `DocumentLifecycleUITests` (10/10 after the corrected fix);
- `LifecycleHoldoutUITests`, `ResponsivenessUITests`, `SourceGrantHoldoutUITests`;
- the `ContrastEvidenceUITests` captures;
- CoreTasks T01, T17, T20, T24.

**VoiceOver column: Blocked for every task** (§5).

| ID | Keyboard result (XCUITest key events + AX focus/value) | Notes |
| --- | --- | --- |
| T01 Create a show | **Pass** (mini, main `6e35da2`, scoped policy) | ⌘N → save panel → name → ⇧⌘G folder → Create. File created; title equals the name; "0 episodes"; Saved only after the verified create. Focus starts in the episode list. Audit: no unwaived issues. |
| T02 Add an episode | **Pass** | ⇧⌘N puts focus in the inline rename field (`hasKeyboardFocus`). ⌘Z removes the episode. |
| T03 Metadata | **Pass** (mini `94176b5`, main `6e35da2`, scoped policy) | ⌘I focuses Title and Tab reaches Number. Values persist after ⌘S and reopen. The audit is clean after #112: the clipped Role cell is gone. One new `sufficientElementDescription` heuristic finding (the Name cell labelled with the file name "synthetic-0.wav") gets a scoped structural waiver (§7.1). |
| T04 Collections | **Pass** (menu path); "+" button **Fail** [#110](https://github.com/brandonmartinez/WaveWrangler/issues/110) | Lane suite plus WW-013 (§4.1) |
| T05 Library at scale | **Pass** | 300 keyboard opens and 400 interactions per SCALE-001 execution. Timings in §2.1. |
| T06 Blocked destinations | **Pass** | `LibraryWorkspaceUITests` |
| T07–T13 Setup | **Pass** | `EpisodeSetupUITests` (fixture engine, simulated provider states). Default-size layout: [#104](https://github.com/brandonmartinez/WaveWrangler/issues/104). |
| T14 Toggle autosave | **Pass** | DUR-026, `DocumentLifecycleUITests.testDynamicToggle` |
| T15 Explicit Save | **Pass** | Never "Saved" before ⌘S; after ⌘S, "Saved" with disk verified |
| T16 Conflict | **Fail vs spec** ([#66](https://github.com/brandonmartinez/WaveWrangler/issues/66), [#125](https://github.com/brandonmartinez/WaveWrangler/issues/125)). Data safety and way forward: **Pass** (mini `94176b5`). | ⌘S → AppKit "…changed by another application… Save anyway?" → Save → the base check refuses with "could not be saved. Expected r1/…, found r2/…" plus "Your changes are still open and a copy is kept on this Mac…" [OK]. Return dismisses it; Esc doesn't, because there's no Cancel button. Status "Not saved. Couldn't save: …", never "Saved". ⌘W close sheet: Save / Don't Save / Cancel; **plain Save is offered** (D6 says no plain Save). Choosing it goes through "Save anyway?" and is refused again; the window and edits are kept. **⌥⇧⌘S Save As → keyboard save panel → new document contains the user's edits; the other writer's file is unchanged; window "Conflict Mine"; status "Saved…".** Not a dead end, no data loss. The audit's "Edit the show's title…" finding is the modal dim (§7.1). |
| T17 Recover prior work | **Fail** (audit, mini `de30c99` and `4a109aa`): alert text 2.85–2.95:1, [#126](https://github.com/brandonmartinez/WaveWrangler/issues/126). Functional checks pass. Spec deviation: an alert, not a message bar. | "A complete earlier revision (2) is kept on this Mac…" with "Open Recovered Copy" / "Cancel". |
| T18 Cancel/retry download | **Pass** | `EpisodeSetupUITests` (simulated) |
| T19 Downloads Off | **Pass** (Settings wording) + A-08 | |
| T20 Unknown newer | **Fail** (audit, mini): alert text 2.85–2.95:1, [#126](https://github.com/brandonmartinez/WaveWrangler/issues/126). Refusal is functionally correct. Spec deviation: refused at open. | "Open it with the newer version of WaveWrangler. This version will not edit or save it…" |
| T21 Migration | **Not run** | No older or forced-failure format fixture in the app hooks |
| T22 Unavailable entries | **Pass** | `LibraryWorkspaceUITests` |
| T23 Close/quit unsaved | **Pass** for D3 (DUR-026); **Not run** for D4/D7 (no seam to delay or fail publication in the app) | |
| T24 Two windows / named undo | **Pass** (mini, main `6e35da2`) | Passes with the #86 fix |
| T25 Library location | **Pass** (move to a local folder and back, nothing lost); **Not run** for L1–L5 targets (F-LIBLOC) | §4.1 |
| T26–T28 Folder unreachable | **Not run** | No F-OFFLINE seam in the app's UI-test hooks |
| T29 No connection → Retry | **Pass** | `EpisodeSetupUITests` (simulated) |
| T30 Auto-retry on reconnect | **Not run** | |

### 4.1 WW-013 library management (foreground XCUITest, isolated UI-test storage)

| Step | Result |
| --- | --- |
| Collections via File › Library: New Collection…, Rename Collection, ⌥⌘↓, Add to Collection ▸, ⌫ with confirmation | **Pass**. Shows were kept. |
| Sidebar header "+" | **Fail** [#110](https://github.com/brandonmartinez/WaveWrangler/issues/110). The control is merged into the section heading as static text with no press action. |
| File › Library › Rebuild Library Index… | **Pass, zero semantic loss.** Every sidebar row and value is identical before and after. |
| Relaunch persistence (#97) | **Pass** |
| Settings › Library location → Choose Folder… → "Move your library to “Library Folder”?" → Move Library, then back to In WaveWrangler | **Pass** both ways. Nothing lost. |

## 5. VoiceOver (A11Y-002, C02): Blocked

- **Mac mini attempt (`475adf3`):** see §10.3. No announcement captured. Listening is a user-manual exit item.

Earlier attempt on the 18-core host:

- **Original state:** VoiceOver off. No `com.apple.VoiceOver4` domain, and no `voiceOverOnOffKey` override.
- Background computer-use can't deliver ⌘F5 ("no_viable_candidate") or VO commands. Opening VoiceOver.app through the tool started only the first-run "VoiceOver Quickstart" splash, which the tool can't see. Its three processes were stopped by PID within about 90 s.
- **Verified afterwards:** VoiceOver off, and no VoiceOver preference domain was created.
- `VoiceOverWalkUITests` reads what VoiceOver *speaks* from its caption panel. It's ready for a run with VoiceOver on.
- **No VoiceOver result is claimed.**

### 5.1 Manual VoiceOver checklist (user-only verification item)

**Setup**
1. Build with `scripts/build.sh`. Use synthetic data only: `scripts/demo/make-synthetic-episode.sh` writes `$TMPDIR/ww-m1-demo`.
2. Turn VoiceOver on with ⌘F5. Keep the caption panel visible and the default verbosity.
3. Use the keyboard and VO commands only: VO = ⌃⌥, VO-→/← moves, VO-Space activates, VO-Shift-↓/↑ interacts.

**How to record a result**
- **Pass** needs all three: the task completes, what you hear matches the "Hear" column, and focus doesn't move unless you moved it.
- Turn VoiceOver off afterwards with ⌘F5 and confirm it's off.

| T | Do | Hear (role — label — value; announcements) |
| --- | --- | --- |
| T01 | ⌘N → name → ⇧⌘G temp folder → Return → Create | Save panel; then window "<name>", outline "Episodes" "0 episodes", button "New Episode". After the verified create, the save status reads "Saved …". |
| T02 | ⇧⌘N → title → Return; ⌘Z | Text field "Episode title" in edit mode; row "<n> <title>". After ⌘Z the row is gone and focus is in the list. |
| T03 | ⌘I → Title → Tab → Number "abc" | Text field "Title"; text field "Number" with hint "A whole number…"; "Number: Enter a whole number". Edit menu: "Undo Edit Title". |
| T04 | File › Library › New Collection… → name → ⌥⌘↓ → Add to Collection → ⌫ | Row "<name>, collection" "0 items" → "1 item"; "Delete the collection “<name>”? The shows and episodes in it aren't deleted."; after deletion the selection moves to the adjacent collection. Check whether the sidebar "+" is reachable at all ([#110](https://github.com/brandonmartinez/WaveWrangler/issues/110)). |
| T05 | ⇧⌘L; arrow through the sidebar; Tab into the list | Outline "Library sidebar"; "Shows" "<n> shows", "Recent" "<n> items", "Unavailable" "<n> items need attention"; list "Shows (<n>)". |
| T06 | ⌘2 | "Alignment" "Not available in this version"; heading "Alignment isn't available yet"; button "Go to Setup". Focus stays on the control. |
| T07 | ⌘1, ⇧⌘I, choose the folder | Sheet "Import <n> Sources into “…”"; "Include <file>" checkboxes; "Recorder group for <file>"; download line; skipped reasons; "Imported <n> sources" once. |
| T08–T10 | Group / epoch / channel / speaker / primary from menus and the inspector | "Recorder group" "<name>"; "Epoch" "1"; "Channel" "… not checked against the file"; "Speaker" "<name>"; "Role" Primary/Backup; disabled Role hint "Choose a speaker first". |
| T11 | Relink a moved file | Status "Not found" or "Moved"; comparison sheet ("Size — Recorded … — Chosen … — Same/Different"); checkbox "I've checked this is the same recording" when details differ. Focus returns to the row. |
| T12 | Needs permission → Source › Grant Access… | "Needs permission" (never "Not found"); the panel is pre-pointed at the folder. |
| T13 | Inspector on a source | Location / Access / Residency / Transfer / Identity each read their exact text plus "Checked <time>". "Offline" never appears. |
| T14/T19 | ⌘, → General / Sources | "Save changes automatically" on/off with its caption; "Download sources automatically" on/off with its caption. |
| T15 | Autosave Off, edit, ⌘S | "Edited…" → "Saving…" → "Saved…". "Saved" is announced once, after ⌘S only. |
| T16 | Another writer changes the file; ⌘S | AppKit "Save anyway?", then "could not be saved…"; status "Not saved. Couldn't save: …". Never "Saved". |
| T17 | Open a damaged newest file | Alert with "Open Recovered Copy" / "Cancel" |
| T20 | Open a newer-format file | "… could not be opened. Open it with the newer version of WaveWrangler…" |
| T23 | Autosave Off, edit, ⌘W / ⌘Q | "Do you want to save the changes you made to “…”?" with Save / Don't Save / Cancel. Esc = Cancel. |
| T24 | New Window; edit in one window, ⌘Z in the other | Both windows titled with the show; "Undo <action>". The change is reflected in both. |
| T25 | Settings › Library location → Choose Folder… → Move Library | Pop-up "Library location" "In WaveWrangler"; sheet "Move your library to “…”?"; "Moving library — …". Focus returns to the pop-up. |
| T26–T30 | (no simulated-offline seam) | Record as Not run |

## 6. Visual (A11Y-003, C03–C07): in-app overrides only

- **OS-level settings weren't exercised.** Originals recorded: `com.apple.universalaccess` has no `increaseContrast`, `reduceMotion`, `reduceTransparency` or `differentiateWithoutColor` keys (defaults, off). `FontSizeCategory.global = DEFAULT`. Appearance Dark. Nothing was changed, so nothing needed restoring. **The OS-level visual pass (Increase Contrast, Reduce Motion, larger text) is a user-only item.**
- **In-app overrides run** (`ContrastEvidenceUITests.testVisualOverridesLightDarkReduceMotion200`, `testTextSize200Screenshots`, `testSaturationZeroShowWindow`, `testLibraryMessageBarAt200`; `241396a`/`68d78a0`):
  - `-WWUITestAppearance aqua|darkAqua`;
  - `-WWForceReduceMotion YES`;
  - in-app Text Size 200% (⌘+ ×5);
  - captures of the Library window and of Setup with F-STATES, each also at saturation 0.

| Condition | Result |
| --- | --- |
| C03 200%, Setup (zoomed window) | **Pass** on the re-measurement (Mac mini `475adf3`, §10.1): Setup aqua and darkAqua 200% have no unwaived findings. Earlier: **Fail (unresolved).** Under the scoped policy, mini `479eb9e` left the darkAqua "Access denied" status cell unwaived at p75 1.77 with 5,305 px. That run predates #112's Setup layout and attached no crop (§7.2). It is re-measured in the C04/C05 slot. Earlier observations: Names, statuses, units and button titles are readable. Long statuses wrap mid-word and truncate ("Downloadin g 42% +1…"). Whether the full value reaches help and VO wasn't checked here; it's covered by the lane's T13/T18 AX assertions. Screenshot: [`screens/setup-light-200-zoomed.png`](ww-007/screens/setup-light-200-zoomed.png). Audit findings on that surface are rows cut off at the scroll-view edge (pixel 1.2–1.8:1 because they're partly hidden), not colour. |
| C03 200%, Library window | **Fail** [#109](https://github.com/brandonmartinez/WaveWrangler/issues/109). Content overflows above the window: sidebar rows and the message-bar heading end up under the title bar ([`screens/library-dark-200-overflow.png`](ww-007/screens/library-dark-200-overflow.png)). This already happened before this PR (Shows row 10 pt above the window top). It's worse with the #59 fix (84 pt), because the message bar wraps in the narrower column. |
| C04 Increase Contrast | **System setting: Fail** ([#138](https://github.com/brandonmartinez/WaveWrangler/issues/138); §10.2, Mac mini `475adf3`). The earlier note follows: **Not run** (OS level) on the 18-core host. The AppKit `accessibilityHighContrast*` appearance override produced pixel-identical captures, so it doesn't emulate the setting. |
| C05 Reduce Motion | **Not run.** On the Mac mini (`475adf3`) the system setting was applied, the test runner observed it, and the flows completed with it on. Motion itself isn't observable in static captures (§10.2). Earlier note: **Not evaluated.** The flows ran with `-WWForceReduceMotion YES` and completed, but static screenshots can't show motion. Needs a human check (or OS-level Reduce Motion) as part of item 2 in §9. |
| C06 colour independence | **Pass for the captured surfaces.** At saturation 0 every state is carried by text plus symbol shape: "5 need attention", "Downloading 2 sources — progress unknown", "Needs permission…", "Not found", "Ready", "—" / "?" placeholders ([`screens/setup-default-size-saturation0.png`](ww-007/screens/setup-default-size-saturation0.png)). |
| C07 light/dark | **Pass** on the re-measurement (Mac mini `475adf3`, §10.1). None of the `479eb9e` candidates reproduced, and the remaining findings are measured artefacts with crops. The ratios in §7.1 and the accent fix are verified. |

## 7. Contrast: #59 resolution and the audit contrast policy

### 7.0 Audit contrast policy (as implemented)

Pixel measurements use `ContrastMeter`: an element screenshot at 2×, with the background taken as the most common colour. The results are:
- `max`: the single highest-contrast pixel, an upper bound only;
- glyph statistics over pixels ≥ 1.5:1 against the background: the count, the median and **p75**.

A blurred or clipped label has few glyph pixels or a low p75; legible text has many glyph pixels and a high p75.

**`AcceptanceAudit.run`** (`WaveWranglerUITests/AcceptanceSupport.swift`) handles each `.contrast` finding in this order. The first matching rule applies, and every waiver is recorded per instance in an `audit-<surface>` evidence record, with its glyph statistics and a crop attachment.

1. **Behind a modal sheet.** A sheet is up and the element's midpoint is outside it. The finding is recorded with its measurement as window content dimmed by AppKit.
2. **Offscreen.** The element isn't hittable and has fewer than 20 glyph pixels (scrolled out of view). Recorded.
3. **Occluded.** The element's owning window, resolved through the AX hierarchy (`owningWindowIndex`, matching element type, identifier or label/value, and frame), lies behind another app window that overlaps the element. The screenshot would show the front window's pixels, so the finding is recorded and not measured; that window is audited separately while frontmost. An element of the front window itself is never treated as occluded.
4. **Partly clipped at its window's edge** (`PartialClipContrast`). Only the visible intersection is measured, from the window's own screenshot. The finding is waived only if that part has ≥ 40 glyph pixels at p75 ≥ 4.5; otherwise it stays unwaived.
5. **Measured-artefact surface plus a run-time glyph test.** The element must be in `measuredArtefact`'s scope **and** its screenshot taken now must have ≥ 40 glyph pixels at p75 ≥ 4.5. Otherwise the finding is unwaived. `measuredArtefact`'s scope, each surface measured legible in the cited runs:
   - Library sidebar `ww.library.sidebar.recent` and `.unavailable`;
   - show sidebar `ww.show.sidebar.showInfo` and `ww.show.sidebar.episode.*`;
   - the Episode inspector labels Title, Number, Recording date and Notes, only while the Episode inspector is shown;
   - inspector "Not set";
   - Library entry-table cells, matched by the table's left edge and vertical extent;
   - Setup `ww.setup.source.*` and `ww.setup.group.*` cells;
   - window title-band text (top 52 pt) and `AX_EDITING_STATE`;
   - the "No episodes yet" empty state;
   - `_NS:` text inside a sheet.

Structural waivers (`structuralWaiver`, recorded):
- system window chrome;
- disabled layout groups for `sufficientElementDescription`;
- the pop-up button's AXShowMenu;
- the system emoji item and Siri overlay;
- the AppKit NSAlert icon;
- Setup Name cells labelled with a synthetic fixture file name (`synthetic-N.wav`, `trN.wav`).

**`LibraryWorkspaceUITests.audit`** (Library lane; cross-lane edit authorized by the coordinator in #111) keeps its structural waivers and `OffscreenAuditWaiver` (budget ≤ 5, unchanged). Each contrast finding then goes to `PartialClipContrast`, or, for Library sidebar and entry-table text, to the same per-instance glyph test. Anything else fails. The blanket "#59 tracked" waivers are gone.

**Threshold history (disclosed):**
1. A waiver if the single brightest pixel was ≥ 4.5:1. Superseded: it would have hidden the #59 blur (7.07 / 6.7:1 by that test).
2. ≥ 100 glyph pixels at p75 ≥ 4.5 (#111 review round 1).
3. **2026-10-05, coordinator decision: ≥ 40 glyph pixels (`AcceptanceAudit.minimumGlyphPixels`), p75 ≥ 4.5 unchanged.** This was decided after the mini run at `550506d` observed a legible short word under 100: the "unknown" Location cell, 65 px at p75 12.39.
   - Separation data: blurred #59 row 4 px; clipped or offscreen cells 0 px; shortest legible word 65 px.
   - Every committed and session record was re-evaluated. One classification changed: the same "unknown" cell in mini `479eb9e` "Library darkAqua 100%" is now a measured artefact. A show-sidebar episode row (63 px, p75 1.69) stays unwaived; it is classified in §7.2 as an occlusion artefact.

**Reproducible measurements:** [`ww-007/glyphstat.swift`](ww-007/glyphstat.swift) over [`ww-007/contrast-crops/`](ww-007/contrast-crops/), with output in [`glyphstat-results.txt`](ww-007/contrast-crops/glyphstat-results.txt):
- blurred row 1: 4 glyph pixels;
- fixed row 1: 1,725 / 2,086 at p75 15.91 / 12.39;
- sidebar Recent: 1,047 / 1,164 at p75 18.10 / 15.72;
- sidebar Unavailable: 1,737 / 1,986 at p75 18.10 / 15.72;
- inspector Title / Number / Recording date / Notes (dark): 500 / 890 / 1,679 / 678 at p75 15.72–15.91.

### 7.1 #59: entry list blurred under a Library message bar

| Entry row 1 with a Library message bar shown | Light (aqua, high-contrast aqua) | Dark (darkAqua, high-contrast dark) |
| --- | --- | --- |
| Bar above the split view (original #59, and main after #113) | 4 glyph px (max 7.07–7.57) | 4 glyph px (max 6.7–7.7) |
| **Bar in the content column (this PR)** | **1,725 px, p75 15.91** | **2,086 px, p75 12.39** |

- **Cause.** With the bar above the `NavigationSplitView`, the content column still reserved the toolbar's scroll-edge pocket below the bar. That blurred the column headers and row 1.
  - Before: [`screens/library-light-header-blur.png`](ww-007/screens/library-light-header-blur.png), [`screens/library-dark-header-blur.png`](ww-007/screens/library-dark-header-blur.png).
  - After: [`screens/library-dark-after-59-fix.png`](ww-007/screens/library-dark-after-59-fix.png).
- **Rejected alternatives:**
  - `.scrollEdgeEffectHidden` had no effect;
  - an inset across the whole split view put the bar under the traffic lights.
- **History.**
  1. My first fix put the bar in the content column.
  2. #113 (needed for #109) moved it back above the split view, which brought the blur back on main: mini `9e994b1`, row 1 4 px in all four appearances (`raw-mini-6e35da2-runs.jsonl`, `runD`).
  3. I briefly reverted to main's placement (`019b305`) under the coordinator's rule.
  4. Coordinator decision (a): restore the content-column placement, wrapped in #113's `MessageBarStack` (40 % cap) for #109 (`972acad`).
- **Verification**, Mac mini (macOS 27.0.1, M2 Pro), products `550506d` with main `6e35da2` ([`raw-mini-550506d-runs.jsonl`](ww-007/raw-mini-550506d-runs.jsonl), `runG`):
  - The `ContrastEvidenceUITests` row-1 **assertion** (≥ 40 px, p75 ≥ 4.5) passes in all four appearances.
  - LibraryWorkspaceUITests 7/7 Pass, including 200%. `testLibraryWindowAtScale` passed on the `3b2a878` re-run; in `550506d` it failed only on the 65-px "unknown" cell, under the 100-px rule.
  - LibraryProviderConflictUITests 2/2 Pass; SheetKeyboardUITests Pass.
  - Waived, recorded per instance: 4 partly clipped bottom-row cells (including "5" at y 839–871, window bottom 855) on their visible part, and 11 Library sidebar and table findings by measurement.

### 7.2 Classification of contrast findings (Mac mini runs)

Runs on the Mac mini (macOS 27.0.1, M2 Pro, 12-core/32 GiB); products built on the 18-core host:
- `479eb9e`: the first scoped-policy run, no crops. Raw records: [`audit-records-mini-479eb9e.jsonl`](ww-007/audit-records-mini-479eb9e.jsonl).
- `457dbd1` / `de30c99`, with crops: [`audit-records-mini-de30c99.jsonl`](ww-007/audit-records-mini-de30c99.jsonl).
- `4a109aa` / `550506d` / `3b2a878`: [`raw-mini-6e35da2-runs.jsonl`](ww-007/raw-mini-6e35da2-runs.jsonl), [`raw-mini-550506d-runs.jsonl`](ww-007/raw-mini-550506d-runs.jsonl).

Context for the dates: `479eb9e` predates #112 (fixes #104, Setup layout) and #113 (fixes #109, Library 200 % overflow), but already had this PR's #59 placement.

| Surface (example finding) | Glyph px · p75 | Classification | Status |
| --- | --- | --- | --- |
| **Selected** rows ("Shows", "1 Synthetic Episode…"), `479eb9e` | 1,564–9,484 · **4.02** | **Real failure**: white on the default system-blue selection (#007AFF) | **Fixed in this PR** (`AccentColor` #0064E1 light / #0A6CF0 dark). Verified at `de30c99`/`4a109aa`: text on accent 5.37–8.31; switches 5.28 / 3.37; checkmark 4.88 / 4.35 (`testAccentTintedControls`, crops `contrast-crops/mini-de30c99-accent-*`) |
| **T17/T20 NSAlert text** (`_NS:74`, `_NS:58`) | 6,264–10,462 · **2.85–2.95** | **Real failure**: sharp white text on translucent alert material (crops `contrast-crops/mini-de30c99-audit-crop-T17_*`, `…T20_*`) | [#126](https://github.com/brandonmartinez/WaveWrangler/issues/126) (P1, Mac). T17 and T20 audits = **Fail** |
| T16 "Edit the show's title…" (window content around a document-modal sheet) | 1,029–18,550 · 3.15–3.85 | **Modal dim**, measured from crop `contrast-crops/mini-de30c99-audit-crop-T16_external-change_sheet-10.png` | Rule 1, recorded. T16 = Fail anyway (#66) |
| Show sidebar episode row in C03 `testTextSize200Screenshots`, `479eb9e` | 63 · 1.69 | **Occlusion artefact**: audited after ⌘⇧L put the Library window in front. Audited while frontmost (`3b2a878`): 9,795 px, p75 9.89 | The test now audits the show window while frontmost; rule 3 |
| Setup "Role"/"Speaker" cells "none", 12 pt wide (T03, `479eb9e`/`de30c99`) | 0–384 · 1.06–2.07 | **Clipped column** (#104 layout) | **Correction:** not present in the T03 audit at `94176b5`, but **still present at `475adf3` (after #112)** with the Episode inspector open (§10.1: 0 text pixels). **Unresolved**; re-check on #130's head, and file if it persists. |
| Setup cells with 0 glyph pixels (scrolled) | 0 | Offscreen | Rule 2, recorded |
| Library bottom-row cells at the window edge: "5", "Synthetic Show 017", "iCloud Drive › …", dates (y 833–845, darkAqua 100 % and 200 %, `479eb9e`) | 1,480–4,983 · **1.93–2.16** | **Candidate partly clipped edge cells** (frames extend past the window's bottom edge) | Same position as the "5" cell that `PartialClipContrast` waived on its visible part at `550506d`. **Not reproduced** on the re-measurement (`475adf3`, §10.1) |
| Library date cells x 1170, aqua 100 % / 200 % (`479eb9e`) | 623–1,832 · **4.23–4.42** | **Unresolved candidate.** Just under 4.5; no crop | Re-measured (`475adf3`, §10.1): the cell extends under the scroller; visible text p75 15.91 / 14.92 → **measured artefact** |
| Library 200 % sidebar "Recent" (aqua 2.38 / dark 2.66) and entry "Synthetic Show" 3.34 (`479eb9e`) | 7,724–13,986 · **2.38–3.34** | **Candidate:** predates #113. With #109 the content overflowed under the title bar, so these rows sat in the toolbar's blurred band | **Not reproduced** (`475adf3`, §10.1); it predated #113 |
| **Setup darkAqua 200 % `ww.setup.source.<id>.status` "Access denied; …"** (`479eb9e`) | **5,305 · 1.77** (max 13.11) | **Unresolved candidate.** The text uses the default label colour (`StatusCell`). The same cell in aqua measured 812 px at p75 17.22, so the low p75 with many glyph pixels points to a background region (selection or band) inside the 88×60 frame rather than the text. No crop, and it predates #112's Setup layout | **Not reproduced** (`475adf3`, §10.1): Setup aqua and darkAqua 200% have no unwaived findings. It predated #112. **No product bug.** |
| Unselected show sidebar rows, Library entry cells, Setup cells, title bars, "No episodes yet", "Not set", sheet message text | 114–12,000 · 6.15–17.22 | Legible system text: **measured artefact** | Rule 5, gated per instance |
| C03 Name-cell label "tr1.wav"; C03 Library cells past the outline clip frame | — / 250–2,604 · 12.4–12.6 | Harness scope (heuristic label; table-edge match) | Fixed in the harness. Re-run at `475adf3` (§10.1): the remaining file-name labels "ana-zoom.m4a" and "intro.wav" are the same heuristic |

**Re-measurement done** on the Mac mini at `475adf3`. Results are in §10.1 (C03/C07) and §10.2 (system Increase Contrast: [#138](https://github.com/brandonmartinez/WaveWrangler/issues/138)).

## 8. Findings and issues

| Issue | Severity | Status |
| --- | --- | --- |
| [#84](https://github.com/brandonmartinez/WaveWrangler/issues/84) No "Restore unsaved changes" UI | P1, M1 must-fix | Fixed by #95; verified (DUR-026 routes 9/18) |
| [#86](https://github.com/brandonmartinez/WaveWrangler/issues/86) A focused inspector field kept a discarded draft after Revert or an external change | P1 | **Fixed in this PR**; verified (DUR-026 Revert, T24, all `DocumentLifecycleUITests`) |
| [#104](https://github.com/brandonmartinez/WaveWrangler/issues/104) Setup shows one Sources row at the default size; Role/Status clipped | P1 | Fixed by #112; T03 passes on the mini |
| [#105](https://github.com/brandonmartinez/WaveWrangler/issues/105) First open p95 1.048 s (holdout) | P1 | Fixed by #107; post-fix p95 461 ms |
| [#106](https://github.com/brandonmartinez/WaveWrangler/issues/106) "Shows" sidebar selection 165–177 ms (holdout) | P1 | Fixed by #108; post-fix p95 52 ms |
| [#59](https://github.com/brandonmartinez/WaveWrangler/issues/59) Entry list blurred under a Library message bar | real failure | **Fixed in this PR** with option (a). It had regressed on main via #113. Verified on the mini at `550506d`; every Library suite passes with measured waivers. |
| [#109](https://github.com/brandonmartinez/WaveWrangler/issues/109) Library window content overflows at in-app 200% | P1 (C03) | Fixed by #113; its 200% test passes on the mini with main's placement |
| [#110](https://github.com/brandonmartinez/WaveWrangler/issues/110) Sidebar "New Collection" (+) isn't an accessible button | P1 | Fixed by #113 (`ww.library.collections.add`); LibraryManagement passes on the mini |
| [#66](https://github.com/brandonmartinez/WaveWrangler/issues/66) No D6 Conflict / Save Mine as a Copy after Save Anyway | P2 (M2) | Existing; T16 cites it |
| [#125](https://github.com/brandonmartinez/WaveWrangler/issues/125) Save-conflict alert shows internal revision IDs | P2 (M2) | Filed by Design; T16 |
| [#126](https://github.com/brandonmartinez/WaveWrangler/issues/126) T17/T20 alerts: white text on translucent alert material, 2.85–2.95:1 | P1 | Filed by Design; T17/T20 audits Fail |
| AccentColor: white on the default system-blue selection measured 4.02:1 | real failure | **Fixed in this PR:** `AccentColor` #0064E1 light / #0A6CF0 dark; verified on the mini. Design spec updated. |
| UI-test runs wrote source access records into the user's device-local store | test isolation | **Fixed in this PR**. `WaveWrangler-UITests/DeviceAccess` is used in UI-test runs, plus a `-WWUITestResetSourceAccess YES` hook. |

## 9. User-only and remaining exit items

1. **VoiceOver listening (A11Y-002): user-manual.** Run the §5.1 checklist with VoiceOver on. The Mac mini attempt couldn't capture announcements (§10.3).
2. **Reduce Motion (C05): motion behaviour by eye.** The system setting is honoured in code (`MotionPolicy`) and the flows completed with it on, but motion can't be observed headlessly.
3. Manual Full Keyboard Access run of the K-flows (spec §6).
4. DUR-026 Dock › Quit route by hand.
5. Main-thread source/provider I/O trace after #55. Attach `xctrace` by PID.

## 10. Follow-up: Mac mini slot `475adf3` (C03/C07 re-measurement, C04/C05, VoiceOver)

**Run record**
- **Host:** Mac mini (M2 Pro), macOS 27.0.1, 12-core / 32 GiB, under the coordinator GUI lock, 2026-10-05 17:04–17:38.
- **Build:** products built on the 18-core host at `475adf3`, whose test and harness code is identical to this PR's (rebased onto main).
- **Driver:** [`visual-vo-slot.sh`](ww-007/visual-vo-slot.sh); its log is [`visual-vo-slot-475adf3.log`](ww-007/visual-vo-slot-475adf3.log).
- **Raw records:** [`raw-mini-475adf3-slot.jsonl`](ww-007/raw-mini-475adf3-slot.jsonl).
- **Reproducible measurements:** [`contrast-crops/glyphstat-475adf3.sh`](ww-007/contrast-crops/glyphstat-475adf3.sh) runs [`glyphstat.swift`](ww-007/glyphstat.swift) (now with an optional `@x,y,w,h` region) over the crops in [`contrast-crops/mini-475adf3-*`](ww-007/contrast-crops/). It lists the **exact region of every figure** (image pixels, origin top-left, 2× crops); output is [`glyphstat-results-475adf3.txt`](ww-007/contrast-crops/glyphstat-results-475adf3.txt).
- **Consent:** the user granted temporary Increase Contrast, Reduce Motion, larger text and VoiceOver on the mini (2026-10-05). Originals were recorded first and restored afterwards (§10.4).

### 10.1 C03/C07 re-measurement at the system originals

Tests: `testVisualOverridesLightDarkReduceMotion200`, `testSaturationZeroShowWindow` and `testTextSize200Screenshots`. All three passed (their audits are record-only). Current rules are those of §7.0.

| Earlier candidate (`479eb9e`, §7.2) | Now (`475adf3`) |
| --- | --- |
| Library darkAqua bottom-row cells, p75 1.93–2.16 | **Not reproduced** (no unwaived finding at those cells) |
| Library 200% "Recent" 2.38 / 2.66, "Synthetic Show" 3.34 | **Not reproduced.** Library aqua and darkAqua 200% have no unwaived findings. These predated #113 (#109 overflow). |
| **Setup darkAqua 200% "Access denied" status, 1.77** | **Not reproduced.** Setup aqua and darkAqua 200% have no unwaived findings. It predated #112's Setup layout. **No product bug.** |
| Aqua date cells (x 1170), 4.23 | Still flagged at 4.23. The crop shows the cell extends under the vertical scroller and the detail column; only "Se" is visible. **Visible text: 207 px at p75 15.91 / 14.92.** → **measured artefact** (scroller pixels). The truncation itself (Last Opened cut off, Status off-screen at the default window size) is a readability issue: [#140](https://github.com/brandonmartinez/WaveWrangler/issues/140) (P2, Library lane). |

Remaining findings in this run, classified from their crops:
- **Setup selected row "intro.wav … Not found", p75 2.27** (Name, Speaker, Role and Status cells). Each cell is measured from **its own crop** (`contrast-crops/mini-475adf3-setup-selected-row-{name,speaker,role,clipped}.png`).
  - The row is a **selected** row cut off by the Sources table's scroll edge: the top 14 px band is the accent selection; below it is the table background (#1E1E1E).
  - In every full crop, the 2.27 "glyph" figure is the **accent fill against #1E1E1E**, not text.
  - **Status** visible band: 297 px at p75 7.35 (#FFFFFF on #004DC4) → measured artefact (scroll-edge clip).
  - **Name** visible band: 207 px at p75 7.35 → measured artefact (scroll-edge clip).
  - `PartialClipContrast` handles window edges only, so the harness records these as unwaived; they are classified here.
  - **Speaker and Role: unresolved.** Each column is 12 pt wide and its crop has **0 text pixels** (no white at all): the "none" value isn't drawn. That is the **#104 clipped-column signature, at `475adf3`, after #112.** It occurs here with the Episode inspector open, which narrows the table. #130 (fix for P0 #129) changes the Setup column mechanism (constant ideal column widths). **To re-check on #130's head once it merges; if the clipping persists, file it.**
- **Sidebar "Synthetic Collection 3" (darkAqua), 2,753 px at p75 15.72.** Legible, but collection rows aren't in `measuredArtefact`'s scope → measured artefact.
- **200% Library bottom-row cells (y 850, visible slice 5 pt).** Name, "1" and location: 0 glyph pixels. No text is rendered in the visible sliver (the row lies below the window edge) → clipped, not colour.
- **Unresolved:** the date cell at {1170, 850} in the same row has **56 glyph pixels at p75 1.61** in the 5-pt visible slice. There's no crop of the slice, so its pixels can't be classified.
- **"Label not human-readable" for fixture file names** "ana-zoom.m4a" and "intro.wav". These are the same file-name heuristic as `synthetic-N.wav` / `trN.wav`; the names are outside the harness waiver's pattern.

**C03 Setup: Pass. C07: Pass.**

### 10.2 C04/C05 with the system settings (Increase Contrast, Reduce Motion, larger text)

- **Settings in effect.** Set at 17:24:19 and re-read at 17:24:23:
  - `increaseContrast = 1` (boolean), `reduceMotion = 1` (boolean), `FontSizeCategory = {global = XXXL}` (dictionary);
  - the probe reported increaseContrast=true and reduceMotion=true;
  - the **test runner** recorded `increaseContrast: true, reduceMotion: true, reduceTransparency: false, bodyFontPointSize: 13.0`;
  - `testSystemVisualSettings` asserts both settings and **passed**.
- **Larger text had no effect** on AppKit's preferred body font (13 pt): `FontSizeCategory` drives only some system apps. **Larger text (system) = Not run.** In-app 200% is the tested path.
- **#59 row 1 under system Increase Contrast:** the assertion (≥ 40 px, p75 ≥ 4.5) **passed**.
- **Real failure: the selected Library sidebar row ("Shows").**
  - Under Increase Contrast it draws its label in a light blue tint on the dark accent fill #0A6CF0: **1,433 px at p75 2.33** (100%), **5,393 px at p75 2.33** (200%).
  - Without Increase Contrast the same row is white at 4.76–5.37.
  - → [#138](https://github.com/brandonmartinez/WaveWrangler/issues/138) (P1; Design accent decision, with Mac).
  - Crops: `contrast-crops/mini-475adf3-ic-sidebar-shows-selected-{100,200}.png`; screen: [`screens/mini-475adf3-system-increase-contrast-library.png`](ww-007/screens/mini-475adf3-system-increase-contrast-library.png).
- **Measured artefacts under Increase Contrast** (Increase Contrast draws heavier borders and scrollers, which the crops include):
  - date cells at x 1170, 2.86 → visible "Se" text 253 px at p75 12.08;
  - "Library" title band, 3.69 → title text 1,129 px at p75 16.29;
  - the Setup selected clipped row, 3.51 (the accent fill #0A6CF0 against #1E1E1E): Status visible band 282 px at p75 4.76 and Name visible band 198 px at p75 4.76 → measured artefacts. **Speaker and Role: 0 text pixels**, unresolved, the same as §10.1 (#104 signature).
- **Unresolved, no crop.** Two bottom-row cells partly below the window edge: "5" (visible slice 10 pt, 333 px at p75 4.11) and a date cell (2.0). The visible slice probably includes Increase Contrast's window border. They stay unwaived and are not classified.
- **C05 Reduce Motion: Not run.** The setting was in effect (the runner observed it) and the flows completed with `MotionPolicy` honouring it, but motion isn't observable in static captures. Checking motion by eye is a user item.
- **C04: Fail (#138).**

### 10.3 VoiceOver (A11Y-002)

What was attempted:
1. At 17:33:00 the script set `com.apple.VoiceOverTraining doNotShowSplashScreen` and started VoiceOver with `open -a /System/Library/CoreServices/VoiceOver.app`. VoiceOver ran as pid 21864.
2. `VoiceOverWalkUITests` (3 walks) drove the app by keyboard and read VoiceOver's caption panel through XCTest after each step, also cropping the panel's pixels.
3. **All 3 walks failed at the first step** (`Failed to resolve query: Timed out snapshotting 'VoiceOver', app is either unresponsive or taking too long to snapshot`). The test bundle exited 65.

**Disclosure:** at the `vo-on` snapshot (17:33:08), with VoiceOver pid 21864 running, the probe read **`isVoiceOverEnabled` = false**. `voiceOverOnOffKey` wasn't snapshotted then; it read 1 only after the slot. **VoiceOver may never have been enabled during the walks.** `open -a VoiceOver.app` starts the process, but that apparently doesn't (or didn't yet) turn VoiceOver on. That is consistent with the caption panel not being snapshot-able.

**No announcement was captured, and none is claimed.** **VoiceOver listening is a user-manual exit item** (checklist §5.1).

### 10.4 Restoration (recorded, then diffed against the originals)

| Key | Original (17:04:34) | After the slot (17:37:52) | Final (20:13–20:20, after manual steps) |
| --- | --- | --- | --- |
| `com.apple.universalaccess increaseContrast` | 0 (boolean) | 0 (boolean) | 0 (boolean) ✅ |
| `… reduceMotion` | absent | absent | absent ✅ |
| `… reduceTransparency` | 0 (boolean) | 0 (boolean) | 0 (boolean) ✅ |
| `… FontSizeCategory` | absent | absent | absent ✅ |
| `com.apple.VoiceOver4/default` | absent | absent | absent ✅ |
| `com.apple.VoiceOverTraining` | absent | **present (empty plist)** | absent ✅. The coordinator authorized deleting it. `defaults delete` reports "Domain not found" for an emptied domain, so the empty 42-byte plist file (contents `{}`) was removed and re-read as absent. |
| `com.apple.universalaccess voiceOverOnOffKey` | **not snapshotted.** Inferred off: the original probe reported `isVoiceOverEnabled` = false. An absent key and `0` can't be told apart that way. | 1 | **0 (boolean)**, restored with the coordinator's authorization at **20:19:59** (`defaults write com.apple.universalaccess voiceOverOnOffKey -bool false`, writing false rather than deleting the key). Re-read at 20:20:01: `0`, Type is boolean; probe `voiceOver=false`; no VoiceOver process. If the original was an absent key, the residual difference is "absent → 0 (false)", which is functionally off. |
| VoiceOver process | none | none | none ✅ |

Before the restore, `voiceOverOnOffKey` read 1 and the probe reported `voiceOver=true`. The key was set because the slot stopped VoiceOver with `kill` rather than quitting it through VoiceOver. This is a **slot-script gap**: the script didn't snapshot that key. False is the restored state, matching the original probe.

The slot script is now fixed for reuse:
- it snapshots `voiceOverOnOffKey`;
- it quits VoiceOver through AppleScript before falling back to kill;
- it removes emptied plist files.

No orphan processes remained, and the run folder on the mini was removed after the bundles were fetched.

### 10.5 VoiceOver listening attempt via computer-use (this Mac, 2026-10-05 22:02–22:05)

**Host:** this Mac (MacBook, macOS 27.0.1, 18-core), user-directed GUI window, consents A/B/D.

**Originals, recorded first (22:00:00):**
- `com.apple.universalaccess`: increaseContrast, reduceMotion, reduceTransparency, voiceOverOnOffKey and differentiateWithoutColor were absent.
- FontSizeCategory.global was DEFAULT, and AppleInterfaceStyle was Dark.
- The VoiceOver4 and VoiceOverTraining domains were absent, and VoiceOver wasn't running.

**What was attempted:**
1. Fixture: the Debug app at `0e4bad9` with `-WWUITestHooks YES -WWUITestLibraryFixture lib100` (in-memory library, no user data). The Quickstart splash was suppressed (`VoiceOverTraining doNotShowSplashScreen`).
2. **Cmd-F5** sent with computer-use `press_key` to the app **did not** turn VoiceOver on: the system hotkey wasn't delivered.
3. **System Settings › Accessibility › VoiceOver toggle** (`AX_VOICEOVER_ENABLED`, clicked with computer-use) **turned VoiceOver on** at 22:04:00: probe `isVoiceOverEnabled` = true, VoiceOver pid 92230.
4. **Caption panel not readable:** `get_window_state(com.apple.VoiceOver)` returned `no_window`, and `list_apps` doesn't list VoiceOver, so computer-use can't read the caption panel's text.
5. The first keyboard step in WaveWrangler (↓ in the sidebar) returned **interrupted**: "user input was detected". Either the user was active or VoiceOver moved focus; the cause can't be told apart. Per the coordinator's rule, the attempt stopped.
6. VoiceOver was turned **off with the same toggle** (value 0), not killed. No VoiceOver process remained.

**Restoration** (shell, after the UI workflow, 22:05:24): increaseContrast and voiceOverOnOffKey deleted; the VoiceOver4 and VoiceOverTraining domains and their plist files removed. **Every recorded key matches its original.** The probe reports all false. The fixture app was terminated; no orphans.

**Result: A11Y-002 = Blocked. No announcement was captured, and none is claimed. VoiceOver listening is a user-manual exit item** (checklist §5.1).

