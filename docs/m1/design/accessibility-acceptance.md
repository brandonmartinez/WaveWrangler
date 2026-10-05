# M1 accessibility acceptance suite

**Owner:** Design · **Status:** test specification only. **Nothing in this document has been executed.** · **Refs:** [WW-007 (#8)](https://github.com/brandonmartinez/WaveWrangler/issues/8), [WW-011 (#2)](https://github.com/brandonmartinez/WaveWrangler/issues/2), [WW-012 (#9)](https://github.com/brandonmartinez/WaveWrangler/issues/9), [WW-013 (#12)](https://github.com/brandonmartinez/WaveWrangler/issues/12).

Companion documents: [information architecture](information-architecture.md) · [states and recovery](states-and-recovery.md) · [commands and keyboard](commands-keyboard.md) · [sources](sources.md).

> **Execution permission is pending.** Running these tasks means launching the WaveWrangler GUI, running XCUITest UI tests, using VoiceOver and, for some checks, changing macOS accessibility settings (Increase Contrast, Reduce Motion, colour filters, Full Keyboard Access). The M1 kickoff does **not** authorise GUI launches or GUI/OS-setting changes. That permission is **awaiting the user's answer via the coordinator**. Until it is granted, every task's result is **Not run**, and no row may be reported as passed. The pure-logic checks in §4.1 need no GUI and may run under ordinary `swift test`/`xcodebuild test`.

## 1. Rules for recording results

- Allowed results: **Pass**, **Fail** (with finding), **Blocked** (with reason, e.g. "GUI permission pending"), **Not run**. Missing evidence is never Pass.
- Record for each run: date, host (OS build, hardware), app revision, the build command, which checks were automated vs manual, the assistive technology and its settings, and the fixture ID.
- The WW-007 denominator for "100% core M1 keyboard/VoiceOver tasks" is **T01–T24** below, each in both the **Keyboard** and **VoiceOver** modes (48 task-mode cells). Each cross-cutting condition in §3 then runs over the task subset listed there.
- Claimed host: macOS 27.0.1 / Xcode 27 / 18-core Apple silicon / 128 GiB. This is **not** the macOS 26 / 16 GB reference; reference-device results belong to Release WW-052.

## 2. Fixtures (synthetic only)

All fixtures are generated in temporary directories by the test target. **No user recordings or sample folders are used.** Source files are generated placeholder files with audio extensions; M1 never reads their content. Provider states (cloud-only, downloading, paused, failed, no connection, denied, stale) are **simulated** through Mac's injectable state-observation seam, and results are labelled "simulated provider state". Real iCloud/OneDrive/Dropbox behaviour needs separate consent and is out of scope here.

| Fixture | Contents |
| --- | --- |
| F-EMPTY | Empty library, no shows |
| F-LIB100 | 100 shows, 1,000 source references total (WW-007 scale), 5 collections, 3 unavailable entries (not found, needs permission, newer format) |
| F-MESSY | Folder tree with 2 recorder subfolders (`ZOOM0001/tr1.wav, tr2.wav, tr3.wav`), a laptop folder (`Ana/ana-zoom.m4a`), 2 non-recording files, 1 hidden file, 1 file already in the episode, and 1 *same-named* but different-size file |
| F-STATES | One episode whose sources cover **every** value of every dimension in [states §3](states-and-recovery.md#3-source-states-five-independent-dimensions) at least once, plus combined cases (e.g. needs permission + cloud-only + not checked) |
| F-CONFLICT | A show open in the app, then modified on disk by the test harness through a separate writer |
| F-RECOVER | A show whose newest save is deliberately incomplete, with a prior complete version present |
| F-NEWER | A show written with an unknown newer format version |
| F-OLDER / F-OLDER-BAD | An older supported format; an older format whose migration is forced to fail |

## 3. Cross-cutting conditions

| ID | Condition | How applied | Applies to | Pass criteria |
| --- | --- | --- | --- | --- |
| C01 | **Keyboard only**, Full Keyboard Access on | No pointer events | T01–T24 | Task completes using only [K-flows](commands-keyboard.md#8-keyboard-only-flows-for-core-tasks); every focused element shows a system focus ring or row highlight [A9]; no keyboard trap; Esc/⌘. cancel every sheet |
| C02 | **VoiceOver** | VO navigation and VO-commands only | T01–T24 | Every element in the task has the role, label and value listed below; reading order sidebar → content (message bar first) → inspector; announcements per [states §7](states-and-recovery.md#7-announcements); no unsolicited focus change [A2, A9] |
| C03 | **200% text** (in-app Text Size 200%, CMD-20) | Settings › General › Text size = 200% | T01, T03, T05, T07, T08, T10, T11, T15–T17, T19 | No essential text (names, states, units, numbers, button titles) clipped or overlapping. Truncated text exposes its full value in the help tag, VO label and inspector. Meaningful symbols scale. The task still completes with C01 |
| C04 | **Increase Contrast** | System setting (needs consent), **or** debug launch override `-WWForceIncreaseContrast YES` for automated runs, labelled "override, not system setting" | T07, T10, T11, T15–T17, T19, T22 | Text meets the A1 ratios (4.5:1 ≤ 17 pt; 3:1 ≥ 18 pt or bold) in light and dark mode; state symbols remain distinguishable; `contrast` audit passes |
| C05 | **Reduce Motion** | System setting (needs consent) **or** override `-WWForceReduceMotion YES` | T01, T05, T10, T17–T19, T21 | No sliding/zooming pane or sheet transitions beyond the system's; spinners may animate (system), but no custom animation conveys meaning [A1, A20]; destination changes cross-fade or switch instantly |
| C06 | **Colour independence** | Grayscale colour filter (needs consent) **or** a snapshot rendered with saturation 0 | T07, T10, T11, T15, T17, T19, T22 | Every state in F-STATES is distinguishable by text + symbol shape alone; no state differs only by tint [A1, ST-02] |
| C07 | **Light and Dark appearance** | App appearance override in tests | Same as C04 | No state relies on a colour that disappears in either appearance [A19] |

## 4. Automated structural checks

### 4.1 Pure logic (no GUI; may run now under ordinary tests)

| ID | Check | Implementation hint |
| --- | --- | --- |
| A-01 | **Symbol resolution:** every SF Symbol name in the states catalog resolves on the **deployment target** (macOS 26) and on the build host | Unit test iterating the catalog's symbol table: `NSImage(systemSymbolName:accessibilityDescription:) != nil` |
| A-02 | **Wording catalog:** every save state D1–D16, source dimension value, library entry state and blocked destination maps to exactly the text in [states](states-and-recovery.md) / [IA](information-architecture.md#42-destinations) | Table-driven test against a presentation model (e.g. `SaveStatusPresentation`, `SourceStatusPresentation`) |
| A-03 | **Summary priority:** combining five dimensions yields the summary text and VO value order in [states §3.6](states-and-recovery.md#36-combining-dimensions-for-the-table-summary); no input produces the word "Offline" | Exhaustive enumeration over all dimension value combinations |
| A-04 | **Honest save state:** only a coherent-publication result yields D1; uncertain, cancelled, failed, queued and autosave-OFF results never clear dirty | State-machine test over the transition rules ST-10–ST-14 |
| A-05 | **Undo names:** each command registers the name in [commands §3](commands-keyboard.md#3-named-undo-actions) | Unit test on the command layer with an `UndoManager` |
| A-06 | **Shortcut register:** the main menu contains exactly the [custom register](commands-keyboard.md#custom-shortcut-register) and no duplicate key equivalents | Walk `NSApp.mainMenu` in a hosted unit test (no UI automation needed; Mac to confirm whether instantiating the menu counts as a GUI launch) |
| A-07 | **Defaults:** fresh preferences give Autosave **On**, Download sources automatically **On**, Text size **100%** | Unit test on the settings store |
| A-08 | **Downloads Off ⇒ no requests:** with Off, import/open/relink of F-STATES issues zero content/hash/header/preview/decode/download calls through the instrumented file-access seam | Mac-owned WW-006/012 test; Design acceptance requires its result before T19 can pass |

### 4.2 UI automation (XCUITest) — needs GUI permission

- Run `XCUIApplication.performAccessibilityAudit(for:)` [A25] at the end of each task step that shows a new surface. Use the audit types **available on macOS**: `.contrast`, `.elementDetection`, `.hitRegion`, `.sufficientElementDescription`, `.action`, `.parentChild` [A26]. `.textClipped`, `.dynamicType` and `.trait` are **not** listed for macOS, so C03 clipping is checked manually or with screenshot review.
- Assert the AX tree by stable identifiers ([IA §7](information-architecture.md#7-accessibility-identifiers-for-xcuitest-and-ax-tree-checks)), element type, `label`, `value` and enabled state, and assert focus with `hasKeyboardFocus` where the API exposes it.
- Drive keys with `typeKey(_:modifierFlags:)` / `typeText(_:)`. Never click in C01 runs.
- Announcements can't be asserted through XCUITest. Verify them manually with VO (or with Accessibility Inspector's notification log, **unverified** capability).

### 4.3 Manual

The manual checks are VoiceOver listening tests (C02), the real system settings for C04–C06 (each needs consent), C03 clipping review, and a cross-check with Accessibility Inspector [A27]. Follow Apple's method: list the main tasks, build a settings × assistive-technology matrix, and complete every task under each one [A24].

## 5. Core task suite

Notation: **Role** uses the XCUITest element type (AppKit AX role in brackets; exact AX role names are **expected, to be confirmed** with Accessibility Inspector). **Auto** = XCUITest + audit; **AX** = AX-tree assertion; **VO** = manual VoiceOver. Every task also has the implicit criteria: completes under C01 and C02, no colour-only state, no lost work, focus returns to the invoking control after sheets close.

| ID | Task (issue) | Fixture · K-flow | Expected AX: role — label — value | Focus & announcement | Pass criteria | Automation |
| --- | --- | --- | --- | --- | --- | --- |
| T01 | Create a show (WW-011) | F-EMPTY · K01 | Save panel `sheet`; new window title = show name; `outline`/`table` [AXOutline] `ww.show.sidebar.episodes` — "Episodes" — "0 episodes"; `button` — "New Episode" | Focus lands in the new window's episode list; no alert | The show file exists at the chosen location; the library lists it; the save-status value is "Saved…" only after D1 | Auto + AX; VO |
| T02 | Add an episode (WW-011) | T01 result · K02 | `outlineRow` — "Episode 1" (in edit: `textField` — "Episode title") | Inline rename focused; "Undo New Episode" in Edit menu | Episode appears and is selected; undo removes it and restores selection | Auto + AX; VO |
| T03 | Edit episode and show metadata (WW-011) | T02 · K03, K04 | `textField` — "Title"; `textField` — "Number" — numeric string; `datePicker` — "Recording date"; `textView` — "Notes" | Focus moves only on ⌘I/Tab; per-field undo names ("Undo Edit Title") | Values persist after ⌘S + reopen; invalid number shows inline error text "Enter a whole number" and the label stays | Auto + AX; VO |
| T04 | Organise collections (WW-011) | F-LIB100 · K05, K06 | `outlineRow` [AXRow] — "<name>, collection" — "<n> items"; menu items "Add to Collection" | No focus jump when an item is added; "Undo Add to Collection" | Membership survives app relaunch and **Rebuild Library Index…**; removing from a collection deletes nothing | Auto + AX; VO |
| T05 | Open, reopen and navigate the library at scale (WW-007, WW-011) | F-LIB100 · K21, K24, K25 | `outline` `ww.library.sidebar`; `table` `ww.library.entries` — "Shows" — row count; segmented `ww.show.destination` — "Destination" — "Setup" | Restored focus/selection on reopen | Opening works through Open Recent and the library. p95 open/interaction timing is **recorded** (WW-007 budget <1 s / <100 ms on the claimed host), not assumed | Auto (timing via signposts) + AX |
| T06 | Blocked destinations (WW-011) | Any show · K24 | `radioButton`/segment — "Alignment" — "Not available in this version"; `group` `ww.show.blocked.alignment` with `staticText` heading "Alignment isn't available yet"; `button` — "Go to Setup" | Focus stays on the segmented control; the heading is announced | Segment focusable and selectable, reason readable, Go to Setup works; no command for M2–M4 work exists | Auto + AX; VO |
| T07 | Import a messy folder (WW-012) | F-MESSY · K07 | `sheet` `ww.import.review` — "Import 9 Sources into “…”"; `checkBox` — "Include tr1.wav" — on/off; `popUpButton` — "Recorder group for tr1.wav" — "Zoom H6, suggested"; `staticText` download line | Sheet focus on the table; on Import, imported rows selected; "Imported 9 sources" announced | Non-recordings and hidden files are skipped with reasons; the existing file is excluded as "Already in this episode"; the same-named different file is listed separately; Cancel changes nothing; unconfirmed suggestions are not applied; zero source writes | Auto + AX; VO |
| T08 | Confirm/correct grouping (WW-012) | T07 · K08 | `popUpButton` `ww.inspector.source.group` — "Recorder group" — "<name>"; group `outlineRow` — "<name> — recorder group" — "<n> sources" | Selection stays on the moved rows; "Undo Assign to Group “…”" | Works with menu, inspector and context menu; works for multi-selection; drag is not required | Auto + AX; VO |
| T09 | Set epoch and channel numerically (WW-012) | T07 · K09 | `textField` + `incrementor` — "Epoch" — "1"; `textField` — "Channel" — "2, not checked against the file" / "unknown" | ↑/↓ steps; invalid input shows text error | Epoch ≥ 1 enforced; Channel accepts Unknown; values are labelled provisional; nothing reads file headers | Auto + AX; VO |
| T10 | Assign speaker; choose primary and backup (WW-012) | T07 · K10 | `popUpButton` — "Speaker" — "Ana"; `radioGroup` — "Role" with `radioButton` "Primary"/"Backup"; speakers `table` row — "Ana" — "Primary tr1.wav channel 1, 1 backup" | Disabled Role explains "Choose a speaker first" (help + VO hint) | Use as Primary demotes the old primary to Backup; "Undo Change Primary for “Ana”"; Unassigned is valid; the Speakers status reads "Choose primary" when none | Auto + AX; VO |
| T11 | Relink a missing source (WW-012, WW-006) | F-STATES (Not found; same-named decoy at the old path) · K11 | `cell` `ww.setup.source.<id>.status` — "Status" — "Not found"; `sheet` `ww.relink.sheet`; comparison `table` rows "Size — Recorded 1.21 GB — Chosen 1.21 GB — Same"; `checkBox` — "I've checked this is the same recording" | No default button when details differ; focus returns to the row after | The decoy is **not** auto-linked; a match relinks after confirmation; a mismatch needs the checkbox; undo restores the old state; the original file is unmodified (Mac file-audit) | Auto + AX; VO |
| T12 | Regrant access (WW-012, WW-006) | F-STATES (Needs permission, Denied) · K12 | Status values "Needs permission" vs "Access denied" (never "Not found") | Grant Access… panel pre-pointed at the folder | Denied and Needs permission are distinct in text and symbol; regrant still runs the identity comparison | Auto + AX (simulated); VO |
| T13 | Read every source state (WW-012) | F-STATES | Inspector `ww.inspector.location/access/residency/transfer/identity` each `staticText` with the exact [states §3](states-and-recovery.md#3-source-states-five-independent-dimensions) text + "Checked <time>" | — | All five rows are present for every source; the table summary and VO value match §3.6; no "Offline" anywhere; "Details match" text says the audio wasn't compared | Auto + AX; VO |
| T14 | Toggle autosave (WW-005, WW-011) | Any writable show · K13 | `checkBox` [AXCheckBox/AXSwitch] `ww.settings.autosave` — "Save changes automatically" — "on"/"off" | — | Off: an edit shows D3 "Not saved", the close-button dot and the Window-menu dot; On: D2 without a dot, then D1 after a coherent save; toggling never shows "Saved" falsely | Auto + AX; VO |
| T15 | Explicit Save (WW-005, WW-011) | Edited show · K15 | `button`/toolbar item `ww.show.saveStatus` — "Save status" — "Saving…" → "Saved. Saved at <time> …" | "Saved" announced after ⌘S only | Dirty clears only on D1; on simulated failure the value is "Not saved…" with reason and remedies; the prior version is retained (Mac byte check) | Auto + AX; VO |
| T16 | Resolve a conflict (WW-005, WW-049) | F-CONFLICT · K16 | Save status value "Conflict. “…” was changed somewhere else…"; `sheet` — "Resolve changes to “…”"; default `button` — "Save Mine as a Copy…" | High-priority announcement once | Neither version is overwritten without Keep Mine + confirmation; Save Mine as a Copy creates a new show; the other version stays intact | Auto + AX; VO |
| T17 | Recover prior work (WW-005) | F-RECOVER · K17 | `group` `ww.show.messageBar` — heading "Opened the last complete version"; menu "Revert To" items; `sheet` version list `table` | The message bar persists (not timed); focus is not stolen on open | The last complete version opens and the incomplete save isn't used; Revert works and is reversible | Auto + AX; VO |
| T18 | Cancel and retry a download (WW-012) | F-STATES (simulated provider), downloads On · K18 | `progressIndicator` — "Downloading tr2.wav" — "42 percent" or no percent value when unknown; `button` — "Cancel Download"/"Retry Download" | Progress announcements at most at 25% steps and ≤ every 10 s; failure announced once | Indeterminate never shows a percent; Cancel confirms when progress would be lost; Retry recovers; the source file is unchanged | Auto + AX (simulated); VO |
| T19 | Downloads Off / metadata-only (WW-012, WW-006) | F-STATES, downloads Off · K14 | `checkBox` `ww.settings.downloadSources` — "Download sources automatically" — "off"; Transfer text "Downloads are off"; Residency "In the cloud — not downloaded" | — | The caption matches exactly; A-08 shows zero content/download requests; explicit Source › Download fetches only that source | AX + A-08; VO |
| T20 | Unknown-newer refusal (WW-005) | F-NEWER · K19 | `group` message bar — "This show needs a newer WaveWrangler"; menu items Save/Duplicate/Save As/edit commands `isEnabled == false`; save status "Read-only" | Heading announced | No edit, save or down-save possible; file bytes unchanged | Auto + AX; VO |
| T21 | Migration needed and failed (WW-005) | F-OLDER, F-OLDER-BAD | `sheet` — "Update “…” to the current format?" with `button` "Update" (default), "Open Read-Only", "Cancel"; failure message bar "Couldn't update this show" | — | The original is preserved in both cases; failure leaves a read-only view | Auto + AX; VO |
| T22 | Unavailable show in the library (WW-011) | F-LIB100 unavailable entries · K25 | `outlineRow` — "Unavailable" — "3 items need attention"; entry status cells "Can't find show file" / "Needs permission" / "Needs newer WaveWrangler" | — | Each entry has a distinct reason and remedy; Remove from Library deletes no file and is undoable | Auto + AX; VO |
| T23 | Close/quit with unsaved changes (WW-005) | Autosave Off, edited show · K20 | `sheet` — "Do you want to save the changes you made to “…”?" with buttons Save (default), Cancel, Don't Save | Esc = Cancel; focus returns | No close without a decision; Save failure keeps the window open with the reason | Auto + AX; VO |
| T24 | Multiple windows and named undo (WW-011) | Any show · K22 | Two windows titled with the show name, distinct subtitles; Edit menu "Undo <action>" | Each window keeps its own selection; undo reveals the affected item | An edit in window A shows "— Edited" in both; undo from window B undoes the shared document action and reveals it | Auto + AX; VO |

## 6. Exit criteria for the Design accessibility gate (proposal for Lead)

1. A-01 through A-08 pass in CI.
2. With GUI permission granted: T01–T24 pass under C01 and C02 (48/48 cells). C03–C07 pass on their listed subsets. The XCUITest audits report no unwaived issues, and each waiver has a written rationale.
3. Any Fail in an essential task (T01–T24) is a P0 M1 blocker. It is never transferred to make M1 complete. Broader participant studies and reference-device runs remain WW-052.
4. Results are recorded with the §1 metadata. Simulated provider states are labelled as simulated.
