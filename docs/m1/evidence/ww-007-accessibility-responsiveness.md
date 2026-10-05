# WW-007 integrated accessibility and responsiveness acceptance evidence

**Owner:** Design · **Refs:** [WW-007 (#8)](https://github.com/brandonmartinez/WaveWrangler/issues/8), [WW-011 (#2)](https://github.com/brandonmartinez/WaveWrangler/issues/2), [WW-012 (#9)](https://github.com/brandonmartinez/WaveWrangler/issues/9), [WW-013 (#12)](https://github.com/brandonmartinez/WaveWrangler/issues/12), [#59](https://github.com/brandonmartinez/WaveWrangler/issues/59) · **Spec executed:** [accessibility-acceptance.md](../design/accessibility-acceptance.md) (T01–T30, A-01…A-08, C01…C08)

Results use only **Pass**, **Fail** (with issue), **Blocked** (with reason) and **Not run** (with reason). Missing evidence is never Pass. XCUITest results never stand in for VoiceOver or Full Keyboard Access results. Each holdout execution is reported exactly as executed. Later executions are labelled as re-executions and disclose what changed.

## 0. Summary

| Area | Result |
| --- | --- |
| **SCALE-001 native** (WW-007 timing) | **Holdout (`cb42138`):** first open p95 **1.048 s ❌** ([#105](https://github.com/brandonmartinez/WaveWrangler/issues/105)) and sidebar selection p95 **165 ms ❌** ([#106](https://github.com/brandonmartinez/WaveWrangler/issues/106)); everything else passed. **Post-fix re-execution (`10eb4b8` = main `251d122` with #107 and #108 + this branch): every gate passes.** First open p95 461 ms, sidebar p95 52 ms. Episode switch p95 95 ms, with 4 of 100 samples over 100 ms. |
| DUR-026 native lifecycle ×20 | First attempt (`08f62ee`) **aborted by a harness defect** at scenario 1. Execution on `241396a`: **18 Pass, 0 Fail, 2 Not run** (Dock › Quit, tool limit). |
| REF-020 sandboxed grant ×20 | First execution (`08f62ee`): **16 executed / 4 not executed**. 12 pass; 4 failed on a harness row-selection defect; cycle 5 aborted on a harness defect. Post-correction re-execution (`241396a`): aborted in cycle 2 on panel timing. Full-suite cycle: 4/4 pass. **No product failure observed.** |
| A11Y-001 keyboard full suite | **Executed 1/1** (`241396a`): 45 tests — 36 pass, 6 fail, 3 skipped (VO). Two of the failures were caused by my first #86 fix; the corrected fix was re-verified on `10eb4b8` (§4). |
| A11Y-002 VoiceOver | **Blocked**. Background computer-use can't toggle or drive VoiceOver. Manual checklist in §5.1 (user-only item). |
| A11Y-003 visual | **Executed with in-app overrides only** (light/dark, `-WWForceReduceMotion`, in-app 200%). OS-level Increase Contrast, Reduce Motion and larger text weren't exercised (user-only item). |
| A11Y-004 static audit | **Executed 1/1**: 0 flags (heuristic). |
| #59 | Sidebar and inspector findings are **audit artefacts** (15.7–18.1:1). The entry-table blur under a Library message bar was a **real failure**; it's **fixed in this PR and verified**: row 1 went from 7.07 / 6.7:1 (blurred) to 15.91 / 12.39:1. The fix makes the existing in-app 200% overflow worse ([#109](https://github.com/brandonmartinez/WaveWrangler/issues/109)). |
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
| M1-REF-020 sandboxed grant | 20 | 16 executed, 4 not executed (`08f62ee`) | §2.3 |
| M1-A11Y-001 keyboard full suite | 1 | 1 | §4 |
| M1-A11Y-002 VoiceOver full suite | 1 | **0** | **Blocked** (§5) |
| M1-A11Y-003 visual full suite | 1 | 1 (in-app overrides only) | §6 |
| M1-A11Y-004 static audit | 1 | 1 | §3 |

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
| Post-harness-correction re-execution, `241396a` (fixes `cc41261`, `74c13d9`) | 7 recorded | Cycle 1: grant, relaunch and relink pass; regrant failed because the identity sheet didn't appear (panel timing). Cycle 2: the Import Review didn't appear (panel timing), then the run aborted. **Disclosed; it doesn't replace the first execution.** |
| Full-suite cycle, `241396a` | 4 | 4/4 Pass |

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
| T01 Create a show | **Pass** | ⌘N → save panel → name → ⇧⌘G folder → Create. File created; title equals the name; "0 episodes"; Saved only after the verified create. |
| T02 Add an episode | **Pass** | ⇧⌘N puts focus in the inline rename field (`hasKeyboardFocus`). ⌘Z removes the episode. |
| T03 Metadata | **Pass** (functional); audit **Fail** [#104](https://github.com/brandonmartinez/WaveWrangler/issues/104) | ⌘I focuses Title and Tab reaches Number. Values persist after ⌘S and reopen. |
| T04 Collections | **Pass** (menu path); "+" button **Fail** [#110](https://github.com/brandonmartinez/WaveWrangler/issues/110) | Lane suite plus WW-013 (§4.1) |
| T05 Library at scale | **Pass** | 300 keyboard opens and 400 interactions per SCALE-001 execution. Timings in §2.1. |
| T06 Blocked destinations | **Pass** | `LibraryWorkspaceUITests` |
| T07–T13 Setup | **Pass** | `EpisodeSetupUITests` (fixture engine, simulated provider states). Default-size layout: [#104](https://github.com/brandonmartinez/WaveWrangler/issues/104). |
| T14 Toggle autosave | **Pass** | DUR-026, `DocumentLifecycleUITests.testDynamicToggle` |
| T15 Explicit Save | **Pass** | Never "Saved" before ⌘S; after ⌘S, "Saved" with disk verified |
| T16 Conflict | **Fail vs spec**; data invariant **Pass** | AppKit's "changed by another application… Save anyway?" sheet; choosing **Save** is refused by the base check: "could not be saved… a copy is kept on this Mac". The status AX value is "Not saved. Couldn't save: …" (honest). The other writer's bytes are unchanged. No D6 Conflict state or "Save Mine as a Copy…": [#66](https://github.com/brandonmartinez/WaveWrangler/issues/66) (M2). |
| T17 Recover prior work | **Pass** (spec deviation: alert, not message bar) | "A complete earlier revision (2) is kept on this Mac…" with "Open Recovered Copy" opened the complete version as an unsaved copy; the damaged file was left unchanged. |
| T18 Cancel/retry download | **Pass** | `EpisodeSetupUITests` (simulated) |
| T19 Downloads Off | **Pass** (Settings wording) + A-08 | |
| T20 Unknown newer | **Pass** (spec deviation: refused at open) | "Open it with the newer version of WaveWrangler. This version will not edit or save it". No editable window; bytes unchanged ([#67](https://github.com/brandonmartinez/WaveWrangler/issues/67) catalog sync). |
| T21 Migration | **Not run** | No older or forced-failure format fixture in the app hooks |
| T22 Unavailable entries | **Pass** | `LibraryWorkspaceUITests` |
| T23 Close/quit unsaved | **Pass** for D3 (DUR-026); **Not run** for D4/D7 (no seam to delay or fail publication in the app) | |
| T24 Two windows / named undo | **Pass** | Passes with the #86 fix |
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
| C03 200%, Setup (zoomed window) | **Pass.** Names, statuses, units and button titles are readable. Long statuses wrap mid-word and truncate ("Downloadin g 42% +1…"). Whether the full value reaches help and VO wasn't checked here; it's covered by the lane's T13/T18 AX assertions. Screenshot: [`screens/setup-light-200-zoomed.png`](ww-007/screens/setup-light-200-zoomed.png). Audit findings on that surface are rows cut off at the scroll-view edge (pixel 1.2–1.8:1 because they're partly hidden), not colour. |
| C03 200%, Library window | **Fail** [#109](https://github.com/brandonmartinez/WaveWrangler/issues/109). Content overflows above the window: sidebar rows and the message-bar heading end up under the title bar ([`screens/library-dark-200-overflow.png`](ww-007/screens/library-dark-200-overflow.png)). This already happened before this PR (Shows row 10 pt above the window top). It's worse with the #59 fix (84 pt), because the message bar wraps in the narrower column. |
| C04 Increase Contrast | **Not run** (OS level). The AppKit `accessibilityHighContrast*` appearance override produced pixel-identical captures, so it doesn't emulate the setting. |
| C05 Reduce Motion | **Not evaluated.** The flows ran with `-WWForceReduceMotion YES` and completed, but static screenshots can't show motion. Needs a human check (or OS-level Reduce Motion) as part of item 2 in §9. |
| C06 colour independence | **Pass for the captured surfaces.** At saturation 0 every state is carried by text plus symbol shape: "5 need attention", "Downloading 2 sources — progress unknown", "Needs permission…", "Not found", "Ready", "—" / "?" placeholders ([`screens/setup-default-size-saturation0.png`](ww-007/screens/setup-default-size-saturation0.png)). |
| C07 light/dark | **Pass** after the #59 fix (§7) |

## 7. #59 resolution (contrast)

Pixel WCAG ratios (`ContrastMeter`: element screenshot at 2×; background = the most common colour; text = the highest-contrast pixel):

| Surface | Light | Dark | Verdict |
| --- | ---: | ---: | --- |
| Sidebar unselected rows "Recent", "Unavailable" | 18.1:1 | 15.7–15.9:1 | **Audit artefact.** Keep the identifier-scoped waiver. |
| Episode inspector "Title" / "Number" / "Recording date" / "Notes" (first row under the toolbar) | n/a | 15.7–15.9:1 (#FFFFFF on #222222) | **Audit artefact.** Identifier-scoped waiver. |
| Entry list rows 2 and 5 | 14.9 / 15.9:1 | 11.0 / 12.4:1 | Pass |
| **Entry list headers + row 1 while a Library message bar is shown** | 7.07:1 before (blurred) → **15.91:1** after | 6.7:1 before (blurred) → **12.39:1** after | **Real failure, fixed in this PR** |

- **Cause:** with the message bar above the `NavigationSplitView`, the content column still reserved the toolbar's scroll-edge pocket *below* the bar. That blurred the column headers and the first row (before: [`screens/library-light-header-blur.png`](ww-007/screens/library-light-header-blur.png), [`screens/library-dark-header-blur.png`](ww-007/screens/library-dark-header-blur.png)).
- **Fix:** `LibraryMessageBar` moved to the top of the content column (`.safeAreaInset(edge: .top)`), which also matches IA reading order (after: [`screens/library-dark-after-59-fix.png`](ww-007/screens/library-dark-after-59-fix.png)).
- **Rejected alternatives:**
  - `.scrollEdgeEffectHidden` on the list had no effect;
  - an inset across the whole split view put the bar under the traffic lights.
- **Known cost:** 200% overflow in the Library window ([#109](https://github.com/brandonmartinez/WaveWrangler/issues/109)).
- The acceptance suites use a **pixel-verified** contrast policy (`AcceptanceAudit`): a `.contrast` finding is waived only when the flagged element measures ≥ 4.5:1 or is dimmed behind a modal sheet, and every waiver prints its ratio. The lane suites keep their identifier-scoped waivers.

## 8. Findings and issues

| Issue | Severity | Status |
| --- | --- | --- |
| [#84](https://github.com/brandonmartinez/WaveWrangler/issues/84) No "Restore unsaved changes" UI | P1, M1 must-fix | Fixed by #95; verified (DUR-026 routes 9/18) |
| [#86](https://github.com/brandonmartinez/WaveWrangler/issues/86) A focused inspector field kept a discarded draft after Revert or an external change | P1 | **Fixed in this PR**; verified (DUR-026 Revert, T24, all `DocumentLifecycleUITests`) |
| [#104](https://github.com/brandonmartinez/WaveWrangler/issues/104) Setup shows one Sources row at the default size; Role/Status clipped | P1 | Open (Mac) |
| [#105](https://github.com/brandonmartinez/WaveWrangler/issues/105) First open p95 1.048 s (holdout) | P1 | Fixed by #107; post-fix p95 461 ms |
| [#106](https://github.com/brandonmartinez/WaveWrangler/issues/106) "Shows" sidebar selection 165–177 ms (holdout) | P1 | Fixed by #108; post-fix p95 52 ms |
| [#59](https://github.com/brandonmartinez/WaveWrangler/issues/59) Entry list blurred under a Library message bar | real failure | **Fixed in this PR**; verified. Artefact surfaces documented. |
| [#109](https://github.com/brandonmartinez/WaveWrangler/issues/109) Library window content overflows at in-app 200% | P1 (C03) | Open. Pre-existing; worse with the #59 fix. |
| [#110](https://github.com/brandonmartinez/WaveWrangler/issues/110) Sidebar "New Collection" (+) isn't an accessible button | P2 | Open (menu path works) |
| [#66](https://github.com/brandonmartinez/WaveWrangler/issues/66) No D6 Conflict / Save Mine as a Copy after Save Anyway | P2 (M2) | Existing; T16 cites it |
| UI-test runs wrote source access records into the user's device-local store | test isolation | **Fixed in this PR**. `WaveWrangler-UITests/DeviceAccess` is used in UI-test runs, plus a `-WWUITestResetSourceAccess YES` hook. |

## 9. User-only and remaining exit items

1. VoiceOver run of §5.1, or `VoiceOverWalkUITests` with VoiceOver on (A11Y-002).
2. OS-level visual pass: Increase Contrast, Reduce Motion, larger text, with originals restored (A11Y-003 OS part, C04).
3. Manual Full Keyboard Access run of the K-flows (spec §6).
4. DUR-026 Dock › Quit route by hand.
5. Main-thread source/provider I/O trace after #55. Attach `xctrace` by PID.
