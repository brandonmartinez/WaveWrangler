# M1 repeatable demonstration and consented manual validation

**Owner:** Mac · **Refs:** [WW-013 (#12)](https://github.com/brandonmartinez/WaveWrangler/issues/12), [WW-012 (#9)](https://github.com/brandonmartinez/WaveWrangler/issues/9), [WW-006 (#1)](https://github.com/brandonmartinez/WaveWrangler/issues/1)

This document has two parts:

1. A **repeatable synthetic demonstration** of the M1 organizer, written as copyable keyboard and menu steps, with the result observed when Mac ran it end to end through computer-use automation.
2. A **consented manual validation** on a user-provided local disposable episode copy (path withheld). Only aggregate, generic observations are recorded here.

It is manual evidence for acceptance review. It doesn't replace the automated suites (`scripts/test.sh`), and it never claims evidence that wasn't observed: a step that wasn't run, or couldn't be observed, says so.

## 1. Run record

| Item | Value |
| --- | --- |
| App revision | `f6701801ccafd8efe5deba8264e6201a7ca7977c` (origin/main after #55 merged). This branch adds documentation and `scripts/demo/` only, so the app built from it is the same. |
| Build | `scripts/build.sh` (Debug, ad-hoc signed `CODE_SIGN_IDENTITY=-`, `-jobs 4`, DerivedData in the worktree): **BUILD SUCCEEDED** |
| Host | Mac17,14, Apple M5 Max (18 cores), 128 GiB RAM, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a) |
| Date | 2026-10-05, 05:13–05:39 EDT, in one coordinator GUI-lock slot |
| Driver | Copilot computer-use, a background accessibility engine. It sent real key events, clicked by AX element or screenshot coordinate, and read AX trees. No AppleScript, no System Settings changes. |
| Starting state | Fresh app container library (0 shows, 0 recent, Unavailable None). Preferences at defaults: autosave On, downloads On, text 100 %. |
| End state | Preferences back to defaults (`WWAutosaveEnabled = 1`, `WWDownloadSourcesAutomatically = 1`). The app was quit. The library still has two entries, because the harness could not drive Remove from Library (§6). Both show files were deleted, so the entries will appear as unavailable. |

**Harness behaviour you need to repeat this run.** The background engine's `set_value`/`type_text` change a SwiftUI text field's AX value without updating its binding: the field shows the new text, but nothing is committed. Typing with real key events (one `press_key` per character) works. This is a property of the automation tool, not of the keyboard path a person uses. The engine also can't open `NSPopUpButton` menus or menu-bar menus in the background. Every step that needed one is marked **Not run (harness)**. These steps are still part of the script for a human or for a foreground XCUITest.

## 2. Preparation (repeatable)

Run from the repository root. Everything the demonstration creates lives under `$TMPDIR` or in the consented iCloud trial folder, never in a repository.

```sh
scripts/build.sh                                   # Debug, ad-hoc signed; app at .build/DerivedData/Build/Products/Debug/WaveWrangler.app
scripts/demo/make-synthetic-episode.sh             # writes "$TMPDIR/ww-m1-demo" (refuses to overwrite or to write inside a Git tree)
scripts/demo/fs-manifest.py snapshot "$TMPDIR/ww-m1-demo/Synthetic Episode 1" "$TMPDIR/ww-m1-demo-before.json"
open .build/DerivedData/Build/Products/Debug/WaveWrangler.app
```

The generator writes **16 files**: **9 importable "recordings"** (random bytes with `.WAV`, `.m4a` and `.aif` extensions; nothing is decodable) in three recorder folders, plus **7 decoys** that must be skipped and never opened: a text note, a `.srt` transcript, a peak file (`.pk`), a `.logicx` project folder containing a `.wav`, a hidden file and a `.png`. It also creates an empty `Relink Target` folder.

| Folder | Files | Expected suggestion |
| --- | --- | --- |
| `Recorder A/ZOOM0001` | `ZOOM0001_Tr1.WAV`, `ZOOM0001_Tr2.WAV`, `ZOOM0001_LR.WAV` (+ decoy `ZOOM0001.pk`) | Group "Recorder A", epoch from take folder `ZOOM0001` |
| `Recorder A/ZOOM0002` | `ZOOM0002_Tr1.WAV`, `ZOOM0002_Tr2.WAV` | Group "Recorder A", epoch `ZOOM0002` |
| `Recorder B` | `Alpha mic.m4a`, `Bravo mic.m4a`, `Bravo backup.m4a` | Group "Recorder B"; speakers "Alpha", "Bravo"; "backup" suggests Backup |
| `Recorder C` | `Guest 1 iso.aif` | Group "Recorder C"; speaker "Guest 1" |

`scripts/demo/fs-manifest.py` records, for every entry, a SHA-256 of the relative path plus type, size, mtime, ctime and inode from `lstat`. It never opens or hashes file contents, and it prints only aggregate counts. `compare` exits 0 only when nothing was added, removed or changed.

## 3. Synthetic demonstration script and observed results

Notation: "Menu ›" means choosing the item from the menu bar (by keyboard: ⌃F2, or Help-menu search with ⌘?). K-numbers refer to the [keyboard-only flows](../design/commands-keyboard.md#8-keyboard-only-flows-for-core-tasks). Wording in quotes is the Design catalog wording the step expects.

Results: **Pass** = observed as expected. **Fail** = observed and wrong (issue linked). **Partial** = some expectations met, others failed or not observed. **Not run** = not exercised (reason given). Anything not observed is never marked Pass.

| ID | Steps (keyboard first) | Expected | Observed | Result |
| --- | --- | --- | --- | --- |
| S01 | Launch the app. | Library window: Shows "0 shows", Recent "0 items", Unavailable "None", and an empty state with New Show… and Open…. | As expected. | Pass |
| S02 | ⌘N → name `Synthetic Demo Show` → ⇧⌘G, enter `$TMPDIR/ww-m1-demo/Shows/`, Return → **Create** (K01). | Save panel accessory "Autosave is On. You can change this in Settings." The show window opens and says Saved. | Accessory text exact. Window opens with "No episodes yet". The save-status help reads "Saved at 5:13 AM to “Synthetic Demo Show” in Shows. WaveWrangler saved this Mac's copy. If this folder syncs, your cloud service uploads it separately." | Pass |
| S03 | ⇧⌘N twice (K02). | Episode 1 and Episode 2 appear with inline rename. Destinations Alignment, Review and Export are visible with "Not available in this version". | As expected. Episodes outline value "2 episodes". | Pass |
| S04 | ⌘I → type a title → Tab. Repeat for the second episode. Choose **Add Recording Date** (K03). | Title updates the sidebar and window title. Recording date appears. Edited → Saved (autosave On). | Titles "A" and "B" committed (by key events). Date field and **Remove Recording Date** appeared. Status went Edited → Saved within about 1 s. | Pass |
| S05 | Select episode A → ⇧⌘I → ⇧⌘G, enter `$TMPDIR/ww-m1-demo/Synthetic Episode 1/`, Return → **Choose** (K07). | Panel prompt and accessory as IA §5. Import Review lists 9 sources with provisional suggestions, and the decoys are skipped. | Prompt "Choose recordings or folders to add to “A”"; accessory "WaveWrangler adds references to these files. It never moves, renames or changes them." Sheet "Import 9 Sources into “A”", "From: Synthetic Episode 1 (5 folders, 16 files; 5 not recordings, 2 hidden items, skipped)". Groups Recorder A/B/C and speakers Alpha/Bravo/Guest 1 each marked "suggested", with a reason in the help tag. "13 suggestions weren't accepted and won't be applied." The 2nd hidden item is a `.DS_Store` that the system open panel wrote while browsing *into* the folder; WaveWrangler did not write it (manifest, S10). | Pass |
| S06 | **Accept All Suggestions** → **Import 9**. | Groups and speakers become facts. The import is one step. Duration, channels and sample rate stay Unknown. | Recorder C (1), Recorder B (3), Recorder A (5), Ungrouped 0. Channel "?" (VoiceOver "unknown"). Status "Ready". Role "Backup (not confirmed)" for speaker-assigned rows. Inspector: Duration/Channels/Sample rate Unknown, "WaveWrangler doesn't read audio in this version, so these stay Unknown.", five availability rows each "Checked 5:17 AM". Take-folder epochs were **not** applied: all rows are epoch 1, a known #55 limit (#72). | Pass |
| S07 | Select sources → inspector Role **Primary** / **Backup**, speaker inspector "Make … primary", Epoch stepper (K08–K10). | One primary per speaker, others Backup. The ZOOM0002 take gets epoch 2. Speakers show "Primary chosen". | As expected (Guest 1, Bravo and Alpha primaries; Bravo backup confirmed; ZOOM0002 sources at epoch 2). The Speakers table shows only about one row at any window size ([#89](https://github.com/brandonmartinez/WaveWrangler/issues/89)). | Pass (UX issue) |
| S08 | ⌘S (K15). Then make an edit with autosave On and wait 5 s. | ⌘S → Saved and "— Edited" cleared. Autosave → Saved **and** "— Edited" cleared (A4, ST-10). | ⌘S cleared "— Edited". After an autosave, the status read "Saved at 5:20 AM" but the subtitle kept "A — Edited" until ⌘S. | Fail ([#87](https://github.com/brandonmartinez/WaveWrangler/issues/87)) |
| S09 | ⌘, → General → **Save changes automatically** Off (K13). Edit, wait 6 s, then ⌘W (K20) → **Save**. | Off caption exact. D3 "Not saved". No automatic save. The close sheet offers Save · Don't Save · Cancel. | Caption "Changes are saved only when you choose File › Save (⌘S). WaveWrangler will ask before closing a show with unsaved changes." After 6 s: "Not saved. Autosave is off." The ⌘W sheet "Do you want to save the changes made to the document “Synthetic Demo Show”? / Your changes will be lost if you don’t save them." offered Save · Don’t Save · Cancel. Save closed the window; the edit was present after reopening. AppKit wording differs slightly from the Design text ("changes you made to"). | Pass |
| S10 | ⌘Q. Then compare the fixture manifest before and after import. | The app quits. No fixture file changes. | Quit cleanly. Manifest: 0 fixture files changed. 1 entry added (the panel's `.DS_Store`) and the folder's mtime changed because of it. | Pass |
| S11 | Relaunch → Library → select the show → **Open Show** (K21). | The entry shows its last location, episodes and last-opened time, and opens. | Entry: Episodes "—", Location "Location unknown", Last opened "Not yet", Status "Checking…" forever. **Open Show** → "WaveWrangler doesn't know where this show is saved on this Mac. Use Locate… to choose it." ⌘O worked; groups, primaries and epochs were intact (including the autosave-Off edit saved through the close sheet). | Fail ([#88](https://github.com/brandonmartinez/WaveWrangler/issues/88)) |
| S12 | Outside the app: `mv` one source into `Relink Target/` (same volume), and `chmod 000 "Recorder C"`. Reopen. | Moved/Not found and Access denied are separate states. Denied is never shown as Not found. | "2 need attention". The Recorder C source shows "Access denied +2 more"; its speaker shows "Primary unavailable — Access denied". The moved file shows **Moved**, inspector "Found at a new location (Relink Target)", identity matches: the bookmark followed the move, which is the Design's Moved state. | Pass |
| S13 | Moved source → inspector **Relink…** → ⇧⌘G to the file → Choose → read the sheet → **Use This File** (K11). | Panel message with the recorded details. The sheet compares details (not audio). An exact match has a default **Use This File**. | Message "Choose the recording to use for “ZOOM0001_LR.WAV”. WaveWrangler recorded: 49 KB, created Oct 5, 2026 at 5:07 AM, from folder ZOOM0001." Headline "File details match. WaveWrangler compared file details, not audio." Name, Size, Created, Modified, Kind and File ID all **Same**. "WaveWrangler never moves, renames, copies over or changes either file." After **Use This File**: Ready. Nit: the File ID row shows "Recorded"/"Read" instead of values, and its AX identifier `ww.relink.compare.file id` contains a space. | Pass |
| S14 | The denied source → inspector rows → `chmod 755` → **Try Again** (K12). | Independent dimensions, then recovery. | Location "Location unknown — access was denied, so WaveWrangler couldn't check." Access "macOS or the file's owner denied access." (Try Again · Relink… · Grant Access…). Residency "Can't tell if it's downloaded." Identity "Not checked." After Try Again, all five rows were normal again and the attention count dropped. | Pass |
| S15 | Outside the app: copy one source to `Relink Target/` (new file object) and delete the original. Reopen → "needs attention" filter. | Location "Not found". Access is not a permission problem. | The filter showed only the missing source; Location "Not found". **But** Access read "WaveWrangler needs your permission again" with Grant Access…, so the summary priority can show "Needs permission" for a missing file. | Fail ([#90](https://github.com/brandonmartinez/WaveWrangler/issues/90)) |
| S16 | Missing source → **Relink…** → choose the copy (K11). | "Some file details are different", an unchecked acknowledgement, and no default button. | Headline "Some file details are different: modified, file id." **Use This File Anyway** stayed disabled until "I've checked this is the same recording" was checked; Choose Another… · Cancel · Use This File Anyway. After confirming: 0 need attention. | Pass |
| S17 | ⌘, → Sources → **Download sources automatically** Off, then On (K14). | Exact Off/On captions. No content requests when Off. | Off: "WaveWrangler uses only file names and file details. It doesn't open, read, preview or download source files. You can still download one source at a time with Source › Download." On: "WaveWrangler asks your cloud service to download sources that aren't on this Mac so they're ready for later steps. Downloads use disk space." All fixture sources are local, so no cloud-only transfer could be observed. | Partial (captions only) |
| S18 | ⌘, → General → **Library location** → Choose Folder… → `~/Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial/demo/` → **Move Library** (K26). Then move back to **In WaveWrangler**. | Copy → verify → switch, with ST-33 wording. Collections intact. | The pop-up's menu could not be opened by the background engine (AX press, click and Space all left it closed). The `demo/` subfolder was created and later deleted unused. | Not run (harness) |
| S19 | Library: Collections **+** → name → File › Library › Add to Collection ▸ → rename and reorder (K05). | A collection with members in order. | Menu-bar and context-menu items aren't drivable with this engine. Recent was observed instead: "2 items" after reopening both shows. | Not run (harness) |
| S20 | File › Library › Rebuild Library Index… (ST-31). | Rebuilt with collections intact (zero semantic loss). | Menu-bar item not drivable. Progress UI is tracked in #74. | Not run (harness) |

**Synthetic results: 13 Pass, 3 Fail ([#87](https://github.com/brandonmartinez/WaveWrangler/issues/87), [#88](https://github.com/brandonmartinez/WaveWrangler/issues/88), [#90](https://github.com/brandonmartinez/WaveWrangler/issues/90)), 1 Partial, 3 Not run (harness).** WW-013's "durable show library … organization survives index rebuild" therefore has **no** passing manual evidence from this run.

Other observations, not filed because they weren't isolated:
- **O1:** in one sequence (relink, Try Again, ⌘S), the show showed Saved and then asked to save on ⌘W a moment later.
- **O2:** after a selection change, the setup inspector's Name text kept the previous source's name as its AX value while the visible text changed.
- **O3:** a second show opened as a window tab (macOS automatic tabbing), which hid the first show window from window lists. Expected AppKit behaviour, but worth knowing when following the script.

## 4. Consented manual validation on a real episode copy

**Consent and scope.** User-provided local disposable episode copy (path withheld). It holds a DAW project, two transcript files and recordings from several recorders. It was used only within the user's exact grant: referenced import, show/episode organization, recorder grouping, primary/backup designation, relink validation on a temporary copy, and metadata/file-system observation. File names, folder names, speaker names and titles are **not** recorded here. Generic labels are used. No screenshot of this session is checked in. Nothing was uploaded, played, decoded, analysed, aligned or transcribed. The transcript and project were never opened.

**Zero-write proof.** `scripts/demo/fs-manifest.py` recorded (path hash, type, size, mtime, ctime, inode) for every entry, using `lstat` only and never reading contents. The manifests are stored only under `$TMPDIR`, outside every repository.

| Comparison | Entries | Added | Removed | Changed (type/size/mtime/inode) | ctime-only |
| --- | --- | --- | --- | --- | --- |
| Baseline (04:18) → pre-import (05:29) | 19 → 19 | 0 | 0 | 0 | 0 |
| Pre-import → after import, save and quit (05:34) | 19 → 19 | 0 | 0 | 0 | 0 |
| Baseline → final (05:38) | 19 → 19 | 0 | 0 | 0 | 0 |

The folder was selected from its parent in the open panel, without browsing into it, so the system panel had no reason to write a `.DS_Store` inside it (contrast S05).

| ID | Step | Observation | Result |
| --- | --- | --- | --- |
| R1 | Downloads **Off**. New show saved to a `$TMPDIR` folder. Episode 1 → ⇧⌘I → select the episode folder → Choose. | Import Review: **13 sources**, "2 folders, 16 files; 3 not recordings, skipped". The 3 skipped files are the project file and the 2 transcript files, classified by name and never opened. **2 provisional recorder groups** (5 and 8 sources, by folder) plus Ungrouped 0. Speaker suggestions on 10/13 rows. No epoch suggestions. The review appeared ≤ 13.5 s after the first Choose attempt; that is an upper bound that includes a harness retry, not a measured import time. | Pass |
| R2 | **Accept All Suggestions** → **Import 13**. | All 13 sources **Ready**. Channel "?", Duration/Channels/Sample rate **Unknown** ("WaveWrangler doesn't read audio in this version…"). Identity "File details match … (audio not compared)". Download row "No download requested". Saved automatically. **9 speakers** were created from suggestions; most were device or input words rather than people ([#91](https://github.com/brandonmartinez/WaveWrangler/issues/91)). | Pass (suggestion quality issue) |
| R3 | Confirm grouping. Set Primary for Speaker 1 (Recorder A) and Speaker 2 (Recorder B), and an explicit Backup for Speaker 2's second source. ⌘S. | Roles shown as Primary / Backup; other rows stayed "Backup (not confirmed)". Saved. #87 reproduced (Saved while "— Edited"). Speakers were not renamed to generic names (renaming takes one key event per character with this harness; see Limits). | Pass (generic renaming not done) |
| R4 | ⌘Q → relaunch. | State restoration reopened the show. Groups, both primaries, the backup and all 13 "Ready" states persisted. | Pass |
| R5 | Relink on a temporary copy: the smallest recording was copied (`cp -p`) to `$TMPDIR/…/src/` as **Source 1**, imported into Episode 2 (Import Review "Import 1 Source … (1 file)"), saved, then the copy was moved to `…/moved/`. | Automatically detected as **Moved** ("Found at a new location (moved)", "1 needs attention"). Relink… message showed the recorded size and created date. Sheet: "File details match. WaveWrangler compared file details, not audio." Name/Size/Created/Modified/Kind/File ID all Same → **Use This File** → Ready → ⌘S. The original was never touched. The copy was deleted afterwards. | Pass |
| R6 | Cleanup. | Temporary copy, temporary show document and the iCloud `demo/` subfolder deleted. Preferences restored to defaults. | Done |

**Incident (disclosed).** While setting up Episode 2, four keystrokes were sent in one batch (⇧⌘N, Return, ⇧⌘I, ⇧⌘G). The open panel then chose its restored directory, which was the **parent** of the consented folder. Import Review enumerated that parent's names and metadata: "6 folders, 32 files; 15 not recordings, 4 hidden". The rows were not read or recorded, and **Cancel** was pressed immediately, so nothing was imported or persisted. The enumeration was names and metadata only (no file opened), but it went outside the consented folder. After that, keys were sent one at a time with verification. The original folder's manifest shows 0 changes.

## 5. Issues

Filed during this run (deduplicated against open and closed issues first):

| Issue | Finding | Step |
| --- | --- | --- |
| [#88](https://github.com/brandonmartinez/WaveWrangler/issues/88) | The library forgets show locations after relaunch: "Checking…" forever, and Open Show fails | S11 |
| [#87](https://github.com/brandonmartinez/WaveWrangler/issues/87) | Autosave On: status "Saved" but the window keeps "— Edited" until ⌘S | S08, R3 |
| [#90](https://github.com/brandonmartinez/WaveWrangler/issues/90) | A deleted source is reported as Not found **and** "needs your permission again" | S15 |
| [#89](https://github.com/brandonmartinez/WaveWrangler/issues/89) | The Speakers table is about one row tall at every window size | S07 |
| [#91](https://github.com/brandonmartinez/WaveWrangler/issues/91) | Import suggestions propose device and input labels as speakers | R2 |

Already tracked and confirmed here: take-folder epochs not applied on import (#72); Review Location… not implemented, so Moved needs Relink… (#75).

## 6. Limits

- **Not run, and not counted as passed:** library location move to/from the iCloud trial folder (S18), collections (S19) and Rebuild Library Index (S20). The background computer-use engine can't open pop-up or menu-bar menus. Library durability, combine and index-rebuild evidence for WW-013 must come from a human run of S18–S20 or from foreground XCUITests under the GUI lock.
- **Downloads:** every source was local, so cloud-only residency, queued/downloading transfer and On→Off cancellation were not exercised (S17 checks only the captions). The iCloud provider runs remain in `sources-holdout.md`.
- **Real media:** speakers kept their suggested labels. They were not renamed to generic names, because the harness can't type into SwiftUI fields except one key event per character. This document uses generic labels instead. The import time is an upper bound, not a measurement.
- **Harness, not product:** `set_value`/`type_text` don't commit SwiftUI text fields; real key events do. People and VoiceOver use the keyboard path, which worked.
- **App state left behind:** the app container library still lists the two demo shows, whose files are deleted (they will show as unavailable), because Remove from Library couldn't be driven. Device-local access records in the app container keep metadata and bookmark hints for the 13 real sources and the temporary copy. These are never in canonical documents or the repo; the coordinator or user may reset the container.
- No VoiceOver, text-size, contrast or Reduce Motion checks were run. Accessibility acceptance is a separate lane.
- One run on one host. These are manual observations, not timing evidence (WW-007 budgets were not measured).
