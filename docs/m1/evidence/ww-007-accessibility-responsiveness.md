# WW-007 integrated accessibility and responsiveness acceptance evidence

**Owner:** Design · **Refs:** [WW-007 (#8)](https://github.com/brandonmartinez/WaveWrangler/issues/8), [WW-011 (#2)](https://github.com/brandonmartinez/WaveWrangler/issues/2), [WW-012 (#9)](https://github.com/brandonmartinez/WaveWrangler/issues/9), [WW-013 (#12)](https://github.com/brandonmartinez/WaveWrangler/issues/12), [#59](https://github.com/brandonmartinez/WaveWrangler/issues/59) · **Spec executed:** [accessibility-acceptance.md](../design/accessibility-acceptance.md) (T01–T30, A-01…A-08, C01…C08)

Results use only **Pass**, **Fail** (with issue), **Blocked** (with reason) and **Not run** (with reason). Missing evidence is never Pass. XCUITest results never stand in for VoiceOver or Full Keyboard Access results.

## 0. Summary

| Area | Result |
| --- | --- |
| **SCALE-001 native holdout (WW-007 timing)** | Executed at the frozen counts. Launch, warm open and pooled interactions **pass**. First open in a fresh process **fails** p95 < 1 s (1.048 s, [#105](https://github.com/brandonmartinez/WaveWrangler/issues/105)). Library sidebar selection on its own **fails** < 100 ms (p95 165 ms, [#106](https://github.com/brandonmartinez/WaveWrangler/issues/106)). |
| DUR-026 native lifecycle ×20 | **Blocked** (0/20 holdout). XCUITest automation mode needs user authentication (§1.2). Calibration: every runnable route passes after the fixes. Dock › Quit is **Not run** (tool limit). |
| REF-020 grant/regrant/relaunch ×20 | **Blocked** (0/20 holdout), same cause. Calibration cycle: grant, relaunch and relink pass. The regrant harness fix is unverified. |
| A11Y-001 keyboard suite | **Blocked** (holdout 0/1). Calibration and verification task results are in §4. |
| A11Y-002 VoiceOver suite | **Blocked** (0/1). VoiceOver can't be driven by background computer-use, and the scripted VO walk needs XCUITest (§5). |
| A11Y-003 visual suite | **Blocked** (0/1). No system setting was changed (§6). |
| A11Y-004 static audit | **Executed 1/1**. 0 flags (heuristic, §3). |
| #59 contrast | Sidebar and inspector findings are **audit artefacts** (15.7–18.1:1). The entry table under a Library message bar is a **real failure** (headers and first row blurred). The fix is proposed but unverified (§7). |
| P0s | **None found.** The P1/P2 issues found or fixed in this lane are listed in §8. |

## 1. Run record

| Item | Value |
| --- | --- |
| Host (claimed, **not** the macOS 26 / 16 GB reference, which is WW-052) | Mac17,14, Apple M5 Max (18 cores), 128 GiB, macOS 27.0.1, Xcode 27.0 |
| App revision for the holdout | `cb42138` (tree `aa4f626a322bfd13dfaa77d42ee021f3fbb680c2`): origin/main `c2edf8c` (all fixes #95–#102) plus this branch. It contains the freeze merge `2fcf4d7` (checked with `git merge-base --is-ancestor`). The worktree was clean at run time. |
| Build | `scripts/build.sh` (Debug, ad-hoc signed, `-jobs 4`, DerivedData in the worktree): **BUILD SUCCEEDED** on every revision used |
| Package and unit tests | `scripts/test.sh` on the final tree: `swift test` suites (60, 145, 70, 55 and 41 tests) passed, the serialized timing passes passed, and `WaveWranglerTests` 7/7 passed. xcodebuild then reported "test runner hung before establishing connection" after the 7 tests had passed. That's the same test-daemon condition as §1.2, not a failing test. Baseline on `8aec54b`: all passed. |
| UI tests | `scripts/test.sh --ui -only-testing:…`, Debug, serial, under the coordinator GUI lock. Calibration on `8aec54b`, verification on `c2edf8c`, holdout on `cb42138`. |
| Fixtures | Synthetic only: F-LIB100 (`lib100` / `lib100files`, 97 generated show files with 1,000 metadata-only references), probe-generated `.wwshow` files, the `WW_SETUP_ENGINE=fixture-states` scripted engine, and generated placeholder `.wav` files under the runner's temp directory. No user media, paths or names. |

### 1.1 Instrumentation added for WW-007

- `WaveWrangler/Support/Responsiveness.swift` measures each interval from the input event's own timestamp (`NSEvent.timestamp`, so queueing before the handler counts) to the end of the main run-loop pass that committed the change. That end point is a one-shot `beforeWaiting` observer at the highest order, which runs after AppKit's display cycle and Core Animation's commit. The final frame composition (≤ 1 refresh) isn't included.
- Intervals are emitted as signposts (`com.brandonmartinez.wavewrangler` / `Responsiveness`). In Debug runs with `-WWUITestTimingLog YES` they're also written as `WWTIMING` log lines. Hooks cover launch → library ready, library open → show window committed (`openIndex` distinguishes first and warm opens), library sidebar selection, library edits, show sidebar selection and show edits.
- The UI-test runner is **sandboxed**: it can't read the unified log, run `xctrace` or reach the Dock. Tests therefore print `[phase]` markers, and [`ww-007/collect_timings.py`](ww-007/collect_timings.py) assigns the app's lines to phases afterwards. It reports nearest-rank p95 (`ceil(0.95n)`) and max.

### 1.2 Blocker: XCUITest automation mode (since about 08:37 EDT)

Every `--ui` run after the SCALE-001 holdout failed with "Failed to initialize for UI testing: Timed out while enabling automation mode". `automationmodetool` reports "Automation Mode is disabled. This device requires user authentication to enable Automation Mode." No prompt was visible, and agents must not enter credentials.

**Needs the user:** approve the automation prompt during a run, or run `automationmodetool enable-automationmode-without-authentication`. Everything marked **Blocked (automation)** below is runnable unchanged once that's done:

```sh
TEST_RUNNER_WW_HOLDOUT_SCENARIOS=20 scripts/test.sh --ui -only-testing:WaveWranglerUITests/LifecycleHoldoutUITests -only-testing:WaveWranglerUITests/SourceGrantHoldoutUITests
scripts/test.sh --ui        # full suite = A11Y-001 holdout
```

## 2. Frozen-registry holdout families (m1-freeze-1)

| Family | Frozen | Achieved | Result |
| --- | ---: | ---: | --- |
| M1-SCALE-001 native (first-open / warm / interactions) | 100 / 100 / 400 | 100 executed (99 timed; one app log line wasn't persisted) / 100 / 403 | Executed. Gates in §2.1. |
| M1-DUR-026 native lifecycle | 20 | **0** | **Blocked (automation)**. Calibration in §2.2. |
| M1-REF-020 sandboxed grant | 20 | **0** | **Blocked (automation)**. Calibration in §2.3. |
| M1-A11Y-001 keyboard full suite | 1 | **0** | **Blocked (automation)**. Task results from calibration and verification are in §4. |
| M1-A11Y-002 VoiceOver full suite | 1 | **0** | **Blocked** (§5) |
| M1-A11Y-003 visual full suite | 1 | **0** | **Blocked** (§6) |
| M1-A11Y-004 static audit | 1 | **1** | Executed (§3) |

No count was lowered and nothing was relabelled. The holdout run was done once.

### 2.1 SCALE-001 native results (holdout, `cb42138`)

Raw samples: [`ww-007/scale001-native-raw.jsonl`](ww-007/scale001-native-raw.jsonl). Summary: [`ww-007/scale001-native-summary.json`](ww-007/scale001-native-summary.json). All intervals finished on the main thread. Debug build.

| Stratum | n | p50 | **p95** | **max** | Gate (provisional, claimed host) | Result |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| Launch → library ready (process start → first commit with 100 entries) | 100 | 551 ms | **588 ms** | **640 ms** | < 1 s | Pass |
| First open, fresh process (Return → show window commit) | 99 | 329 ms | **1,048 ms** | **1,116 ms** | < 1 s | **Fail** [#105](https://github.com/brandonmartinez/WaveWrangler/issues/105) |
| Warm reopen, same process | 100 | 219 ms | **247 ms** | **258 ms** | < 1 s | Pass |
| Library sidebar selection | 103 | 38 ms | **165 ms** | **177 ms** | < 100 ms | **Fail** [#106](https://github.com/brandonmartinez/WaveWrangler/issues/106) |
| Collection move (⌥⌘↑/↓, library edit) | 100 | 15 ms | **20 ms** | **43 ms** | < 100 ms | Pass |
| Episode switch | 100 | 69 ms | **81 ms** | **93 ms** | < 100 ms | Pass |
| Episode title edit (per keystroke) | 100 | 17 ms | **28 ms** | **32 ms** | < 100 ms | Pass |
| **All interactions pooled** | 403 | 25 ms | **77 ms** | **177 ms** | < 100 ms | Pass |

- First open is **bimodal**. About 80% of samples take 0.19–0.6 s and about 20% take 0.91–1.12 s. The handler-to-commit time is about the same, so the stall is inside the open path.
- Every slow sidebar sample is a switch to "Shows" (100 rows).
- Harness wall-clock upper bounds are in [`ww-007/runs-evidence.jsonl`](ww-007/runs-evidence.jsonl); they include XCUITest's event synthesis and AX polling.
- `XCTApplicationLaunchMetric` (launch until responsive, F-LIB100 in memory, 9 iterations): average 0.582 s, RSD 5.5%, max 0.636 s.
- The coordinator classified both misses as **M1 P1**. A native re-measurement is planned after the owning lanes' fixes merge.

**Main-thread file I/O.** The File Activity trace in the holdout didn't record: `xctrace --attach WaveWrangler` was ambiguous because another lane's WaveWrangler process was still running. The calibration trace on `8aec54b` (before #55) is in [`calibration-8aec54b-main-thread-io.json`](ww-007/calibration-8aec54b-main-thread-io.json). Across about 35 s of library navigation, show open, edits and autosave, it recorded 3,176 main-thread file syscalls taking 80 ms in total:
- document reads and writes, including autosave publication and `fsync`: about 4.9 ms;
- the app container's Application Support (recovery store): about 17.6 ms;
- system and framework lookups: the rest.

So **document and recovery I/O does run on the main thread** (NSDocument synchronous read/write by design, `canConcurrentlyReadDocuments == false`). It's small at this scale, but it isn't zero. **Provider/source I/O** wasn't exercised in that trace: there were no sources. The source path wasn't traced after #55, so it's **Not run**. Re-run `ResponsivenessUITests/testMainThreadFileActivityTrace` with `xctrace` attached by PID, then [`ww-007/analyze_main_thread_io.py`](ww-007/analyze_main_thread_io.py).

### 2.2 DUR-026 routes: calibration and verification (not holdout)

| Route | `8aec54b` calibration | `c2edf8c` verification |
| --- | --- | --- |
| 1 Close (⌘W), OFF dirty: Cancel keeps work, then Save writes | Pass | Not repeated |
| 2 ⌘Q, OFF dirty: Cancel, then Don't Save (nothing written) | Pass | Not repeated |
| 3 App menu › Quit, OFF dirty: Save writes and quits | Pass | Not repeated |
| 4 Dock › Quit | Not run | **Not run.** The sandboxed runner can't read the Dock's AX tree or send Apple events, and background computer-use can't open the Dock menu. User-manual item. |
| 5 AS01: edit while ON, OFF within the delay → nothing written, Close prompts | Pass | Not repeated |
| 6 AS05: OFF dirty Close › Don't Save | Pass | Not repeated |
| 7 Save As… panel cancelled: nothing written, still dirty | Pass after a harness fix | Pass |
| 8 Revert To › Last Saved Version | **Fail**: the focused field kept the reverted text ([#86](https://github.com/brandonmartinez/WaveWrangler/issues/86)) | **Pass** with the #86 fix in this PR |
| 9 Relaunch with an edit checkpoint present | **Fail** ([#84](https://github.com/brandonmartinez/WaveWrangler/issues/84)) | **Pass** (#95). "Restore Unsaved Changes" restored the title, and the status read "Edited. You have changes that haven't been saved yet." (not Saved). |

### 2.3 REF-020: calibration cycle on `c2edf8c` (not holdout)

| Scenario | Result |
| --- | --- |
| Grant: File › Import Sources… → sandboxed panel (powerbox) → folder → Import Review "Import 2" → Import | Pass. Both sources Ready; the sources' SHA-256 and mtime were unchanged. |
| Relaunch: bookmarks resolve | Pass. Ready. |
| Regrant (no device-local records, `-WWUITestResetSourceAccess YES`) | The status said "Needs permission; location unknown; download state unknown; file details not checked" (permission, never Not found). The panel flow and identity comparison ran. The harness selected the wrong row, so the regrant landed on the other source. The test now regrants the reliably selectable row; that change is **unverified**. |
| Relink after the harness moved a file | Pass. The comparison sheet said "Some file details are different: file id." Relink was confirmed, the source went to Ready, and there were zero source writes. |

## 3. Automated structural checks

| ID | Check | Result | Evidence |
| --- | --- | --- | --- |
| A-01 | Catalog symbols resolve (this host) | Pass | `PresentationTests.everyCatalogSymbolResolves`; `SourceStatusTests` (A-01) |
| A-02 | Wording catalog | Pass | `PresentationTests.exactWordingForKeyStates`, `settingsCaptionsMatchSpecification` |
| A-03 | Summary priority / never "Offline" | Pass | `SourceStatusTests` (A-03 exhaustive), `everyStateHasTextAndNeverSaysOffline` |
| A-04 | Honest save state | Pass | `onlyCoherentSaveSaysSaved`, `onlyD1ClearsDirtyAndEditedSuffix`, `closeDecisionsFollowStateTable` |
| A-05 | Undo names | Pass | `SetupEditCommandTests` (A-05) |
| A-06 | Shortcut register / no duplicates | Pass | `shortcutsAreUniqueAndCustomRegisterMatchesSpecification` |
| A-07 | Fresh defaults | Pass | `freshPreferencesUseProductDefaults` |
| A-08 | Downloads Off ⇒ zero requests | Mac-owned | Covered by the WWSources / WWEpisodeSetup engine tests in `scripts/test.sh` (passed). Not independently re-checked by Design. |
| **A11Y-004** | Static audit, run with [`ww-007/static_audit.py`](ww-007/static_audit.py). Result in [`a11y004-static-audit.json`](ww-007/a11y004-static-audit.json). | **Executed: 0 flags.** 132 controls, 78 identifiers, 54 explicit labels, 7 hints, 18 help tags. No icon-only button without a label, no context-menu item without a menu-bar equivalent, no colour-only status candidate, no drag-only interaction. | Heuristic and source level only. Not a VoiceOver or usability result. |

## 4. Core task suite T01–T30

**Keyboard** = XCUITest key events plus AX focus/value assertions on `c2edf8c`, verification runs, not the holdout. **Lane** means the task is covered by a lane suite (`LibraryWorkspaceUITests` #57, `DocumentLifecycleUITests` #56/#95, `EpisodeSetupUITests` #55) that this lane couldn't re-run on the final tree (automation blocked). **VoiceOver: Blocked for every task** (§5).

| ID | Keyboard result | Notes |
| --- | --- | --- |
| T01 Create a show | **Pass** | ⌘N → save panel → name → ⇧⌘G folder → Create. The file was created; the title equals the name; "0 episodes"; Saved only after the verified create. Audit clean under the pixel-verified policy. |
| T02 Add an episode | **Pass** | ⇧⌘N puts focus in the inline rename field (`hasKeyboardFocus`). ⌘Z removes the episode. |
| T03 Metadata | **Pass** (functional); audit **Fail** [#104](https://github.com/brandonmartinez/WaveWrangler/issues/104) | ⌘I focuses Title and Tab reaches Number. The values persist after ⌘S and reopen. The audit flagged a Role cell scrolled out of view (1.06:1): at the default window size Setup shows one source row and clips Role/Status. |
| T04 Collections | **Pass** (menu path); sidebar "+" button **unverified** | WW-013 run: create via File › Library › New Collection…, Rename Collection, ⌥⌘↓ move, Add to Collection, ⌫ delete with confirmation; shows kept. Clicking the sidebar header "+" (`ww.library.sidebar.newCollection`) didn't open the name dialog in XCUITest; this is likely a hover-revealed control and needs a manual check. |
| T05 Library at scale | **Pass** (keyboard); timing **Fail** [#105](https://github.com/brandonmartinez/WaveWrangler/issues/105) / [#106](https://github.com/brandonmartinez/WaveWrangler/issues/106) | 300 keyboard opens (Tab, arrows, Return) and 400 interactions in the holdout. |
| T06 Blocked destinations | Lane (not re-run) | |
| T07–T13 Setup tasks | Lane (not re-run) | Default-size layout finding: [#104](https://github.com/brandonmartinez/WaveWrangler/issues/104) |
| T14 Toggle autosave | **Pass** | DUR-026 routes 1, 5, 6 and 9 (ON / OFF / dynamic) |
| T15 Explicit Save | **Pass** | Never "Saved" before ⌘S; after ⌘S, "Saved" with disk verified |
| T16 Conflict | **Fail vs spec**; data invariant **Pass** | Another writer published, then edit and ⌘S. AppKit's stock "changed by another application… Save anyway?" sheet (Save / Don't Save) appeared and **Save** was chosen. The base check refused: "could not be saved. Expected r1/…, found r2/…. Your changes are still open and a copy is kept on this Mac." Status AX value: "Not saved. Couldn't save: …" (honest, never Saved). The other writer's bytes were unchanged, and ⌘W didn't discard. There's no D6 "Conflict" state or "Save Mine as a Copy…"; that's [#66](https://github.com/brandonmartinez/WaveWrangler/issues/66) (M2). |
| T17 Recover prior work | **Pass** (spec deviation) | A truncated newest file produced an alert, not a message bar: "A complete earlier revision (2) is kept on this Mac…" with "Open Recovered Copy" / Cancel. That opened the complete version as an unsaved copy; the damaged file was left unchanged. |
| T18 Cancel/retry download | Lane (not re-run) | |
| T19 Downloads Off | Lane (Settings) + A-08 | |
| T20 Unknown newer | **Pass** (spec deviation) | Refused to open with the reason "Open it with the newer version of WaveWrangler. This version will not edit or save it". No editable window opened and the file bytes were unchanged. The spec expects a read-only window ([#67](https://github.com/brandonmartinez/WaveWrangler/issues/67) catalog sync). |
| T21 Migration | **Not run** | No older supported or forced-failure format fixture exists in the app hooks. |
| T22 Unavailable entries | Lane (not re-run) | |
| T23 Close/quit with unsaved changes | **Pass** (D3 routes) / **Not run** (D4, D7: no seam to delay or fail publication in the app) | DUR-026 calibration |
| T24 Two windows / named undo | **Pass** | Passed after the #86 fix; before it, the stale focused draft masked the shared undo. |
| T25 Library location | **Pass** (move to a local temp folder and back, nothing lost) / **Not run** (L1–L5 targets, F-LIBLOC) | WW-013 run, plus Rebuild Library Index… (§4.1) |
| T26–T28 Folder unreachable | **Not run** | No F-OFFLINE seam in the app's UI-test hooks |
| T29 No connection → Retry | Lane (not re-run) | |
| T30 Auto-retry on reconnect | **Not run** | |

### 4.1 WW-013 library management (coordinator request; `c2edf8c`, foreground XCUITest, isolated UI-test storage)

| Step | Result |
| --- | --- |
| Collections create / rename / move / add show / delete (menu bar) | Pass. The sidebar "+" button is unverified (see T04). |
| File › Library › Rebuild Library Index… | **Pass, zero semantic loss.** Sidebar rows and values before = after: Shows 1, Recent 1, Unavailable None, the collection with 1 item. |
| Relaunch persistence (#97) | **Pass**. Identical state after relaunch. |
| Settings › Library location → Choose Folder… (sandboxed panel) → "Move your library to “Library Folder”?" → Move Library | **Pass**. The folder received the library and nothing was lost. |
| Back to In WaveWrangler | **Pass**. Nothing lost. |

## 5. VoiceOver (A11Y-002, C02): Blocked

- **Original state:** VoiceOver off. No `com.apple.VoiceOver4` domain, and no `voiceOverOnOffKey` override (default ⌘F5).
- **Attempt:** background computer-use can't deliver ⌘F5 ("no_viable_candidate") and can't send VO commands (⌃⌥).
- Opening VoiceOver.app through the tool's launch path started only the first-run "VoiceOver Quickstart" splash, which the tool can't see or drive. Its three processes (Quickstart, `scrod`, Braille XPC) were stopped by PID within about 90 s.
- **Restored and verified:** no VoiceOver process, and no VoiceOver preference domain created.
- The scripted walk `VoiceOverWalkUITests` reads what VoiceOver *speaks* from VoiceOver's caption panel, never from the AX tree. It's ready, but it needs XCUITest automation (§1.2).
- **No VoiceOver result is claimed.**

### 5.1 Manual VoiceOver checklist (user-only verification item)

**Setup**
1. Build with `scripts/build.sh`. Use synthetic data only: `scripts/demo/make-synthetic-episode.sh` writes the F-MESSY-like folder `$TMPDIR/ww-m1-demo`.
2. Turn VoiceOver on with ⌘F5. Keep the caption panel visible and the default verbosity.
3. Drive every step with the keyboard and VO commands only: VO = ⌃⌥, VO-→/← moves, VO-Space activates, VO-Shift-↓/↑ interacts.

**How to record a result**
- **Pass** needs all three: the task completes, the announcements match the "Hear" column, and focus doesn't move unless you moved it.
- Note any extra or missing announcement.
- Afterwards, turn VoiceOver off with ⌘F5 and confirm it's off.

| T | Do | Hear (role — label — value; announcements) |
| --- | --- | --- |
| T01 | ⌘N → type a name → ⇧⌘G a temp folder → Return → Create | Save panel; then the new window "<name>", outline "Episodes" "0 episodes", button "New Episode". After the verified create, the save status reads "Saved …". No alert. |
| T02 | ⇧⌘N → type a title → Return; then ⌘Z | Text field "Episode title" in edit mode; row "Episode 1"/"<title>". After ⌘Z the row is gone and focus returns to the list. |
| T03 | ⌘I → Title → Tab → Number "abc" | Text field "Title"; text field "Number" with hint "A whole number…". After "abc": "Number: Enter a whole number" is spoken or reachable next. Edit menu: "Undo Edit Title". |
| T04 | Library: New Collection… → name → ⌥⌘↓ → Add to Collection → ⌫ | Row "<name>, collection" "0 items" → "1 item"; confirmation "Delete the collection “<name>”? The shows and episodes in it aren't deleted."; after deletion the selection moves to the adjacent collection. |
| T05 | ⇧⌘L; arrow through the sidebar; Tab into the table | Outline "Library sidebar"; rows "Shows" "<n> shows", "Recent" "<n> items", "Unavailable" "<n> items need attention"; table "Shows (<n>)". |
| T06 | ⌘2 | Segment "Alignment" "Not available in this version"; heading "Alignment isn't available yet"; button "Go to Setup". Focus stays on the segmented control. |
| T07 | ⌘1, ⇧⌘I, choose the folder | Sheet "Import <n> Sources into “…”"; checkboxes "Include <file>"; pop-ups "Recorder group for <file>"; the download line; the skipped reasons for decoys; "Imported <n> sources" once. |
| T08–T10 | Assign group / epoch / channel / speaker / primary from the menus and inspector | Pop-up "Recorder group" "<name>"; "Epoch" "1"; "Channel" "… not checked against the file"; "Speaker" "<name>"; radio "Role" Primary/Backup; disabled Role hint "Choose a speaker first". Undo names are spoken in the Edit menu. |
| T11 | Relink a moved file | Status "Not found"; sheet with a comparison table ("Size — Recorded … — Chosen … — Same/Different"); checkbox "I've checked this is the same recording" when details differ; no default button when they differ. Focus returns to the row. |
| T12 | Needs permission source → Source › Grant Access… | Status "Needs permission" (never "Not found"); the panel is pre-pointed at the folder. |
| T13 | Inspector on a source | Location, Access, Residency, Transfer and Identity each read their exact text plus "Checked <time>". The word "Offline" never appears. |
| T14/T19 | ⌘, → General / Sources | Switch "Save changes automatically" on/off with its caption; switch "Download sources automatically" on/off with the exact caption. |
| T15 | Autosave Off, edit, ⌘S | Save status "Edited…" → "Saving…" → "Saved…". "Saved" is announced once, after ⌘S only. |
| T16 | Another writer changes the file; ⌘S | Today: AppKit "changed by another application… Save anyway?", then "could not be saved… a copy is kept on this Mac"; status "Not saved. Couldn't save: …" (D6 is #66). Never "Saved". |
| T17 | Open a damaged newest file | Alert "… A complete earlier revision (<n>) is kept on this Mac…" with buttons "Open Recovered Copy" / "Cancel". |
| T20 | Open a newer-format file | Alert "… could not be opened. Open it with the newer version of WaveWrangler…". |
| T23 | Autosave Off, edit, ⌘W / ⌘Q | Sheet "Do you want to save the changes you made to “…”?" with Save / Don't Save / Cancel. Esc = Cancel, and focus returns. |
| T24 | New Window for the show; edit in one window; ⌘Z in the other | Both windows titled with the show name; "Undo <action>". The undo is reflected in both windows. |
| T25 | Settings › Library location → Choose Folder… → Move Library | Pop-up "Library location" "In WaveWrangler"; sheet "Move your library to “…”?" with "Move Library"/"Cancel"; progress "Moving library — …". Focus returns to the pop-up. |
| T26–T30 | (no seam yet) | Not producible without a simulated-offline seam. Record as Not run. |

## 6. Visual settings (A11Y-003, C03–C07): Blocked; originals untouched

- **Originals recorded:** `com.apple.universalaccess` has no `increaseContrast`, `reduceMotion`, `reduceTransparency` or `differentiateWithoutColor` keys (system defaults, off). `FontSizeCategory.global = DEFAULT`. Appearance: Dark.
- **Not changed.** These settings live in pop-up and menu-driven System Settings panes that background computer-use can't drive, and fixture screenshots need XCUITest. Nothing needed restoring.
- **Done without system settings:**
  - C06 saturation-0 captures of the Library window (calibration, light and dark) and of Setup with the F-STATES fixture ([`screens/setup-default-size-saturation0.png`](ww-007/screens/setup-default-size-saturation0.png)). Every visible state is carried by text plus symbol shape: "5 need attention", "Downloading 2 sources — progress unknown", "—" / "?" placeholders. No state differs only by tint. **Pass for the captured surfaces**; the full F-STATES matrix wasn't captured.
  - C07 light and dark Library: see §7.
  - C03 200% in-app text is covered by the lane suite's audit at 200% (#57). This lane's `ContrastEvidenceUITests/testTextSize200Screenshots` is **Blocked (automation)**.
- The `-WWUITestAppearance highContrastAqua|highContrastDarkAqua` override produced pixel-identical captures, so it **doesn't emulate** Increase Contrast. C04 needs the system setting.

## 7. #59 resolution (contrast)

Pixel WCAG ratios from element screenshots (`ContrastMeter`) on `c2edf8c`:

| Surface | Light | Dark | Verdict |
| --- | ---: | ---: | --- |
| Sidebar unselected rows "Recent", "Unavailable" | 18.1:1 | 15.7–15.9:1 | **Audit artefact.** Keep the identifier-scoped waiver. |
| Episode inspector "Title" / "Number" / "Recording date" / "Notes" (first row under the toolbar) | n/a | 15.7–15.9:1 (#FFFFFF on #222222) | **Audit artefact** |
| Entry table name text, rows 2 and 5 | 14.9 / 15.9:1 | 11.0 / 12.4:1 | Pass |
| **Entry table headers + row 1 while a Library message bar is shown** | blurred | blurred | **Real failure** |

When a Library message bar sits above the split view (the in-memory notice, or L2–L5), the content column's toolbar scroll-edge pocket blurs the column headers and the first row until they're illegible. See [`screens/library-light-header-blur.png`](ww-007/screens/library-light-header-blur.png) and [`screens/library-dark-header-blur.png`](ww-007/screens/library-dark-header-blur.png). Without a bar, a computer-use capture of the real library shows crisp headers.

`.scrollEdgeEffectHidden(true, for: .top)` on the `Table` didn't help and was reverted. The proposed fix (unverified, automation blocked): place `LibraryMessageBar` in the content column with `.safeAreaInset(edge: .top, spacing: 0)`. That also matches IA reading order.

#59 stays open for that surface. The acceptance suites use a **pixel-verified** contrast policy (`AcceptanceAudit` in `WaveWranglerUITests/AcceptanceSupport.swift`): a `.contrast` finding is waived only if the flagged element measures ≥ 4.5:1 or is dimmed behind a modal sheet, and every waiver prints its ratio. The lane suites keep their identifier-scoped waivers.

## 8. Findings and issues

| Issue | Severity | Status |
| --- | --- | --- |
| [#84](https://github.com/brandonmartinez/WaveWrangler/issues/84) No "Restore unsaved changes" UI | P1, M1 must-fix | Fixed by #95; verified (DUR-026 route 9) |
| [#86](https://github.com/brandonmartinez/WaveWrangler/issues/86) Focused inspector field keeps a discarded draft after Revert or an external change | P1 | **Fixed in this PR** (`Inspectors.swift`); verified (route 8, T24) |
| [#104](https://github.com/brandonmartinez/WaveWrangler/issues/104) Setup shows one Sources row at the default window size; Role/Status clipped | P1 | Open (Mac) |
| [#105](https://github.com/brandonmartinez/WaveWrangler/issues/105) First open p95 1.048 s | P1 (coordinator) | Open (persistence) |
| [#106](https://github.com/brandonmartinez/WaveWrangler/issues/106) "Shows" sidebar selection 165–177 ms | P1 (coordinator) | Open (library UI) |
| [#59](https://github.com/brandonmartinez/WaveWrangler/issues/59) Entry table blurred under a Library message bar | real failure | Open; fix proposed |
| [#66](https://github.com/brandonmartinez/WaveWrangler/issues/66) No D6 Conflict / Save Mine as a Copy after Save Anyway | P2 (M2) | Existing; T16 cites it |
| UI-test runs wrote source access records into the user's device-local store | test isolation | **Fixed in this PR**. `SetupEngine` uses `WaveWrangler-UITests/DeviceAccess` in UI-test runs, plus a `-WWUITestResetSourceAccess YES` hook. |
| Observed once on `c2edf8c`: toolbar status "Saved" while the window subtitle read "… — Edited", about 1.5 s after an import (fixture engine) | unverified | Possibly transient (#87 area). Not filed; re-check in the visual pass. |

## 9. User-manual and blocked exit items

1. Re-authorize XCUITest automation mode (§1.2). Then run DUR-026 ×20, REF-020 ×20, the full suite (A11Y-001), `VoiceOverWalkUITests` with VoiceOver on (A11Y-002), and the visual pass under Increase Contrast, Reduce Motion and larger text with originals restored (A11Y-003).
2. Manual Full Keyboard Access run of the K-flows (spec §6). Not granted to agents.
3. DUR-026 route 4 (Dock › Quit) by hand.
4. SCALE-001 native re-measurement after #105 and #106.
