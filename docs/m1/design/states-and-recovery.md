# M1 states and recovery

**Owner:** Design · **Status:** specification for M1 implementation. It is **not implemented or tested**. · **Refs:** [WW-011 (#2)](https://github.com/brandonmartinez/WaveWrangler/issues/2), [WW-012 (#9)](https://github.com/brandonmartinez/WaveWrangler/issues/9), [WW-007 (#8)](https://github.com/brandonmartinez/WaveWrangler/issues/8), [WW-013 (#12)](https://github.com/brandonmartinez/WaveWrangler/issues/12). Mechanism and detection belong to Mac (WW-005/006/010/049); this document fixes **what the user is told and offered** for each state that Mac's code reports.

Companion documents: [information architecture](information-architecture.md) · [commands and keyboard](commands-keyboard.md) · [accessibility acceptance](accessibility-acceptance.md) · [sources](sources.md).

## 1. Rules for every state indicator

- **ST-01: Honesty.** A state is shown only when the app has observed it. Until then the indicator reads **"Checking…"**. If observation finished without an answer, it reads **"Unknown"** with the reason. No indicator may claim "Saved" without coherent disk truth. A download never shows a percentage that wasn't reported by the system. A source is never called "Offline" as a catch-all [A8].
- **ST-02: Three channels, colour optional.** Every state has (1) a **text label**, (2) a **distinct SF Symbol shape** and (3) an optional tint from system colours. Shape families: `checkmark` = fine · `pencil` = edited · `questionmark` = unknown/unconfirmed · `exclamationmark.triangle` = needs attention · `xmark.octagon` = failed · `lock` = read-only · `key` = permission · `icloud` = cloud residency · `arrow.down` = transfer. Meaning must survive grayscale, Increase Contrast and colour filters [A1, A19].
- **ST-03: VoiceOver pattern.** label = *what it is* ("Save status", "tr2.wav"); value = *current state text* (exactly the visible wording, plus any non-visible qualifiers); hint only when the action isn't obvious. Symbols carry no separate accessibility element; they are folded into the parent's value [A2].
- **ST-04: Announcements** use `AccessibilityNotification.Announcement` [A31] per §6. Announcements never move focus [A9].
- **ST-05: No time-boxed messages.** Message bars and popovers persist until resolved or dismissed [A1].
- **ST-06: Symbols** must pass the automated symbol-resolution test on the deployment target (see [acceptance](accessibility-acceptance.md#4-automated-structural-checks)). All names below resolved on the macOS 27.0.1 host on 2026-10-04 ([sources](sources.md#sf-symbols-name-check-host-observation-not-a-source)).

Tints: fine = secondary label colour (no tint) · attention = `systemOrange` · failed = `systemRed` · unknown/checking = secondary. In Increase Contrast, use the system's high-contrast variants; do not add custom colours.

**Accent (Design decision, 2026-10-05; evidence [WW-007 §7.1](../evidence/ww-007-accessibility-responsiveness.md#71-contrast-findings-under-the-scoped-policy-mac-mini-run-479eb9e)).** The app sets `AccentColor` = sRGB **#0064E1** for light mode and **#0A6CF0** for dark mode (`NSAccentColorName`), rather than leaving the system default blue (#007AFF). Reason: white text on the default selection measured **4.02:1**, which fails 4.5:1. That covers selected sidebar rows in the Library and show windows, light and dark, and the `.contrast` audit flags it. On #0064E1 white text is **5.37:1**. Scope and effects:
- The app accent applies only while the user's system accent is **Multicolor**, the default. A user-chosen system accent still wins, as the HIG asks [A3], and is the user's choice.
- It tints every accent-derived control: list/table/outline selection, default (Return) buttons, switches when on, checked checkboxes, linear progress fill, the keyboard focus ring and the toolbar destination's 25% accent fill.
- Computed against typical window backgrounds, the accent fill improves in light mode (white 5.37 vs 4.02; #ECECEC 4.55 vs 3.40). In dark mode it is **lower** than system blue (#1E1E1E 3.10 vs 4.15; #323232 2.39 vs 3.19).
- These controls are therefore measured in both appearances by `ContrastEvidenceUITests.testAccentTintedControls`:
  - text on accent must reach glyph p75 ≥ 4.5:1;
  - a fill that alone shows state (switch on, checkbox checked) must reach ≥ 3:1 against its surroundings (WCAG 1.4.11).
- **Dark variant.** With #0064E1 in dark mode, the measured switch fill was #1367E0 against #242424, **2.99:1**, which fails, so a dark variant was added. The first value of #0A6CF0 meets both limits with margin: white 4.76 and #242424 3.26, computed.
- **Measured on the Mac mini, macOS 27.0.1, `de30c99`:**

  | | Light | Dark |
  |---|---|---|
  | Text on accent (selected rows, default button) | 5.37–7.17 | 4.76–8.31 |
  | Switches on | 5.28 | 3.37 |
  | Default button bezel | 5.37 | 3.51 |
  | Toolbar destination text (accent at 25%) | 12.02 | 6.5 |

  Checkbox evidence (checkmark on fill in the selected row; fill against surroundings in an unselected row) comes from the next run.
- The asset is never removed while selection text is below 4.5:1.
- The colour is never the only signal (ST-02).

## 2. Document save states

The **save-status item** sits at the toolbar trailing edge as symbol + short text; activating it opens a popover. Its identifier is `ww.show.saveStatus`. The title suffix and close-button dot follow [A4]. "Dirty" means the window's content has edits that are not confirmed coherently on disk.

| ID | When (Mac reports) | Item text · symbol | Title / dot | Popover (exact wording) | Actions | Dirty |
| --- | --- | --- | --- | --- | --- | --- |
| **D1 Saved** | Latest edits are confirmed on disk as one complete version | "Saved" · `checkmark.circle` | No suffix / no dot | "Saved at 10:42 PM to “The Daily Wrangle” in <folder display name>. WaveWrangler saved this Mac's copy. If this folder syncs, your cloud service uploads it separately." | Show in Finder | No |
| **D2 Edited — autosave on** | Edits exist; Autosave On; next save not yet complete | "Edited" · `pencil.circle` | "— Edited" / **no dot** [A4] | "You have changes that haven't been saved yet. WaveWrangler saves automatically; you can also choose File › Save (⌘S)." | Save Now | Yes |
| **D3 Edited — autosave off** | Edits exist; Autosave Off | "Not saved" · `pencil.circle` | "— Edited" / **dot** on close button and in Window menu [A4] | "Autosave is off. Your changes are saved only when you choose File › Save (⌘S). WaveWrangler will ask before closing." | Save Now · Autosave Settings… | Yes |
| **D4 Saving** | A save (auto or explicit) is in progress | "Saving…" · inline spinner (indeterminate, no percent) | Suffix unchanged until result | "Saving your changes…" | Cancel Save (when cancellable) | Yes until D1 |
| **D5 Save not confirmed** | Write finished but coherence/acknowledgement is uncertain | "Not confirmed" · `questionmark.circle` | "— Edited" (+ dot if autosave off) | "WaveWrangler wrote your changes but couldn't confirm the saved show is complete. Your changes are still open and still count as unsaved. The previous saved version is kept." | Check Again · Save a Copy… | **Yes** |
| **D6 Changed elsewhere (conflict)** | Disk has a different version from another Mac/app/window lineage | "Conflict" · `arrow.triangle.branch` | "— Edited" | "“The Daily Wrangle” was changed somewhere else (another Mac or app) since you opened it. WaveWrangler hasn't overwritten either version." | Resolve… (opens §2.2) | Yes |
| **D7 Location unavailable** | Save location can't currently be reached (provider/volume/folder unavailable) | "Can't reach" · `icloud.slash` | "— Edited" (+ dot if autosave off) | "WaveWrangler can't reach the folder where this show is saved. Your changes are still open in this window, and the last saved version hasn't been changed." Then Autosave On: "WaveWrangler will try again automatically." Autosave Off: "Choose Try Again when the folder is available." | Try Again · Save a Copy Elsewhere… | Yes |
| **D8 Disk full** | Write failed for lack of space | "Not saved" · `xmark.octagon` | "— Edited" | "Couldn't save because “<volume>” is full. Your changes are still open, and the last saved version hasn't been changed. Free up space, then choose Try Again." | Try Again · Save a Copy Elsewhere… | Yes |
| **D9 Couldn't save (other)** | Permission denied, read-only volume, or other failure | "Not saved" · `xmark.octagon` | "— Edited" | "Couldn't save: <plain reason, e.g. 'WaveWrangler doesn't have permission to save in this folder'>. Your changes are still open, and the last saved version hasn't been changed." | Try Again · Save a Copy Elsewhere… · Details | Yes |
| **D10 Save cancelled** | User cancelled before the new version was published | "Not saved" · `pencil.circle` | "— Edited" | "Save cancelled. Your changes are still open; the last saved version hasn't been changed." | Save Now | Yes |
| **D11 Recovered earlier version** | On open, the newest save was incomplete; Mac opened the last complete version | Message bar + item "Recovered" · `clock.arrow.circlepath` | none until edited | Message bar heading "Opened the last complete version". Body: "The most recent save of this show (<time>) didn't finish, so WaveWrangler opened the version saved at <time>. The incomplete save wasn't used and has been kept aside." | Keep This Version (dismiss) · Show Kept Files in Finder | No |
| **D12 Read-only: newer format** | File was written by a newer, unknown WaveWrangler format | Message bar + item "Read-only" · `lock.fill` | No suffix; window shows `lock.fill` beside title | Heading "This show needs a newer WaveWrangler". Body: "“<Show>” was saved by a newer version of WaveWrangler. You can look at it, but editing and saving are turned off so its newer information isn't lost." | Close Show · Show in Finder | Never |
| **D13 Read-only: can't read fully** | File header/structure unreadable; read-only recovery view available | Message bar + item "Read-only" · `exclamationmark.lock` | — | Heading "This show is damaged". Body: "WaveWrangler could only partly read “<Show>”. It opened what it could, read-only, and hasn't changed the file." | Revert To an Earlier Version… (if any) · Show in Finder | Never |
| **D14 Update needed** | File is an older supported format | Sheet on open (before editing) | — | Title "Update “<Show>” to the current format?" Body: "WaveWrangler needs to update this show before you can edit it. The original is kept unchanged as a backup next to it." | **Update** (default) · Open Read-Only · Cancel | — |
| **D15 Update failed** | Migration did not complete | Message bar + item "Read-only" · `xmark.octagon` | — | Heading "Couldn't update this show". Body: "The original is unchanged. You can view it read-only." | Try Again · Show Details | Never |
| **D16 Read-only location** | Opened from a location without write permission | Item "Read-only" · `lock.fill` | — | "You can view this show but WaveWrangler can't save in its folder. Use File › Duplicate to save a copy somewhere you can write." | Duplicate… | Never |

VoiceOver for the save-status item: label "Save status"; value = item text + first sentence of the popover (for example "Not confirmed. WaveWrangler wrote your changes but couldn't confirm the saved show is complete."). Hint: "Shows details and actions."

### 2.1 Transition rules

- **ST-10:** Only **D1** clears dirty state, removes "— Edited" and removes the dot. Autosave attempts, queued saves, cancelled saves and uncertain acknowledgements never clear it.
- **ST-11:** With Autosave **On**, a failed automatic save (D5/D7/D8/D9) shows its state and retries automatically, at most once every 30 s. The popover adds "WaveWrangler will try again automatically." The visible failure state persists through retries; the UI never flickers back to D2 between attempts.
- **ST-12:** With Autosave **Off**, the app never attempts automatic publication and never loops errors. The state stays D3 until the user saves.
- **ST-13:** Toggling Autosave Off→On while D3 starts a normal automatic save of the pending edits. On→Off while D4 lets the in-flight save finish or fail honestly. Queued automatic work is dropped, and the state becomes D1 or D3 accordingly.
- **ST-14:** Read-only states (D12, D13, D15, D16) disable every editing command and Save, Save As and Duplicate-over-original. In D12, Duplicate and Save As are also disabled, because a down-save is prohibited. The reason appears in the message bar, not just through dimmed menu items [A15].
- **ST-15:** A library index update failing after D1 does **not** change the document state. The library entry shows its own state (§5).
- **ST-16: Save a Copy Elsewhere…** (from D5/D7–D9 or the close sheet) opens the native save panel with the name "<Show> copy" and behaves like Save As. The window then edits the new copy, which must reach D1. The original location's last saved version is untouched. The library adds an entry for the copy and keeps the original's entry with its own status (for example "Location unavailable"). The message bar reads: "You're now editing “<Show> copy” in <folder>. The original at <old folder> wasn't changed."

### 2.2 Resolve Conflict sheet (D6)

Title: "Resolve changes to “<Show>”". Body: "This window has changes that aren't saved. The saved show was also changed somewhere else at <time>. Choose what to keep. WaveWrangler won't delete either version."

| Button | Effect | Notes |
| --- | --- | --- |
| **Save Mine as a Copy…** (default) | Native save panel; this window's content becomes a new show. The other version stays untouched at the original location. | Safest choice. Library gets a new entry. |
| **Open Their Version** | Opens the other version in a new read-only window for comparison. This window stays as it is. | Compare side by side; Window menu lists both. |
| **Keep Mine…** | Confirmation: "Replace the other version with yours? The other version will be kept as an earlier version you can restore with File › Revert To." Buttons **Keep Mine** / **Cancel** (Cancel is not default; no default button) [A13]. | Only offered when Mac can retain the other version as a recoverable checkpoint; otherwise hidden and the sheet explains "Keeping both is required for this location." |
| **Cancel** | Closes the sheet; state remains D6. | Esc / ⌘. |

### 2.3 Close, quit and revert

Close or quit **never happens silently while dirty**, whatever the autosave state. Escape = Cancel in every close sheet [A4, A13]. Quit applies these rules to each dirty show in turn; Cancel on any of them cancels the quit.

| State at Close/Quit | Behaviour | Sheet buttons (default first) |
| --- | --- | --- |
| D1, read-only states | Close immediately | — |
| D2 (Autosave On) | Attempt the save first. Close only after D1. If that save ends in D5/D7–D9, continue with that state's row below | — |
| **D4 Saving** | **Wait** for the in-flight save to finish (the window shows "Saving…" and the close is pending; **Cancel Close** in the save-status popover, or Esc while it is open, abandons the close but not the save). Then apply the row for the resulting state (D1 closes) | — while waiting |
| D3, D10 | Message "Do you want to save the changes you made to “<Show>”?" Informative text "Your changes will be lost if you don't save them." | **Save** · Cancel · Don't Save |
| D5, D7, D8, D9 | Message "“<Show>” couldn't be saved: <short reason>." Informative text "Save a copy somewhere else, or your changes will be lost. The last saved version hasn't been changed." | **Save a Copy Elsewhere…** · Cancel · Don't Save |
| **D6 Conflict** | **Never offer a plain Save** (it would overwrite the other version). Message "“<Show>” was changed somewhere else. Choose how to keep your changes before closing." | **Save Mine as a Copy…** · Cancel · Don't Save. **Keep Mine…** appears only under the same condition as §2.2 and still requires its confirmation |

After **Save a Copy Elsewhere…** or **Save Mine as a Copy…** completes as D1 for the new copy, the original window closes. If the copy also fails, the window stays open in its failure state.
- **File › Revert To ›** lists **Last Saved Version** plus up to 10 recent complete versions ("Today 10:40 PM", …), then **Browse Saved Versions…**. Browse opens a list sheet showing time, episode count and a short change description where known. Choosing one shows: "Replace this window's content with the version from <time>? Your current content will be kept as an earlier version." **Revert** / **Cancel**. Reverting is reversible through the same menu. Only coherent complete versions appear [research: prior valid revisions].

## 3. Source states: five independent dimensions

Each source has **five separately observed dimensions**. The inspector's Availability section **always shows all five rows**, each with its own text, symbol and observation time ("Checked 10:41 PM"). They are never merged into one generic status [invariant].

### 3.1 Location — where the file is

| Value | Inspector text | Symbol | Summary text (table) | Remedy |
| --- | --- | --- | --- | --- |
| Checking | "Checking…" | spinner | "Checking…" | — |
| Known | "At its saved location" | `location` | — (no issue) | Show in Finder |
| Moved | "Found at a new location" (+ new folder display name) | `arrow.right.doc.on.clipboard` | "Moved" | Review Location… (accept or relink; accepting is undoable and **does not by itself confirm identity**) |
| Missing | "Not found" | `questionmark.folder` | "Not found" | Relink… · Show Last Folder in Finder |
| Unknown | "Location unknown — <reason>" | `location.slash` | "Location unknown" | Try Again · Relink… |

### 3.2 Access — whether WaveWrangler may read it

| Value | Inspector text | Symbol | Summary text | Remedy |
| --- | --- | --- | --- | --- |
| Granted | "WaveWrangler has permission" | `key` | — | — |
| Stale (refreshable) | "Refreshing permission…" → returns to Granted or Needs permission | spinner | "Checking…" | Automatic; never prompts |
| Needs permission | "WaveWrangler needs your permission again" | `key.slash` | "Needs permission" | **Grant Access…** (native open panel pre-pointed at the last folder; the user re-selects the file; identity check §4 runs) |
| Denied | "macOS or the file's owner denied access" | `hand.raised.slash` | "Access denied" | Show in Finder (to check sharing & permissions) · Grant Access… · Help. **Denied is never shown as "Not found".** |
| Unknown | "Permission unknown — <reason>" | `questionmark.circle` | "Permission unknown" | Try Again |

### 3.3 Residency — whether the content is on this Mac

| Value | Inspector text | Symbol | Summary text | Notes |
| --- | --- | --- | --- | --- |
| Local | "On this Mac" | `laptopcomputer` | — | — |
| Cloud-only | "In the cloud — not downloaded" | `icloud` | "Not downloaded" | Not an error. With downloads Off this is the expected state. |
| Unknown | "Can't tell if it's downloaded" | `questionmark.diamond` | "Download state unknown" | Used when the provider gives no supported signal. No generic provider classifier is invented. |

### 3.4 Transfer — WaveWrangler's download request

| Value | Inspector text | Indicator | Summary text | Actions |
| --- | --- | --- | --- | --- |
| Idle | (row hidden text "No download requested") | — | — | Download (when Cloud-only/Unknown) |
| Queued | "Waiting to download" | `clock` | "Waiting" | Cancel |
| Downloading, known | "Downloading — 42%" | determinate bar, value 0.42 | "Downloading 42%" | Pause* · Cancel |
| Downloading, unknown | "Downloading — progress unknown" | indeterminate bar (never a fake percentage) | "Downloading…" | Pause* · Cancel |
| Paused | "Download paused" | `pause.circle` | "Paused" | Resume · Cancel |
| Cancelled | "Download cancelled" | `xmark.circle` | "Cancelled" | Download Again |
| Failed | "Download failed: <reason>" | `exclamationmark.circle` | "Download failed" | Retry · Details |
| Can't connect | "Can't download — no network connection" | `wifi.slash` | "No connection" | Retry (also automatic when connectivity is observed again, if downloads are On) |
| Downloads off | "Downloads are off" | `slash.circle` | — | Download (one-off) · Settings… |

\* **Pause** is shown only if Mac can genuinely pause and resume that transfer without losing progress. Otherwise only Cancel appears, and the Cancel confirmation applies when progress would be lost [A8]: "Cancel downloading “tr2.wav”? The part already downloaded may be discarded." **Cancel Download** / **Keep Downloading** (default).

### 3.5 Identity — whether this is the same recording

M1 identity is **metadata-only**: name, size, creation/modification dates and file-system identifiers when available. **No content hash or audio read happens in M1.** UI wording must never imply a content comparison.

| Value | Inspector text | Symbol | Summary text | Remedy |
| --- | --- | --- | --- | --- |
| Not checked | "Not checked" | `questionmark.circle` | — (not an issue on its own) | Check Details |
| Details match | "File details match what WaveWrangler recorded (audio not compared)" | `checkmark.seal` | — | — |
| Changed | "This file changed after it was added (<size/date differs>)" | `exclamationmark.arrow.triangle.2.circlepath` | "File changed" | Review… (accept the new details as the same recording, or Relink…) |
| Mismatch | "This isn't the file WaveWrangler recorded (<which details differ>)" | `xmark.seal` | "Different file" | Relink… |

### 3.6 Combining dimensions for the table summary

The Status cell shows **one summary phrase** (the first matching row below), plus "+N more" when other dimensions also need attention. The cell's **VoiceOver value lists every non-normal dimension** in this order, for example "Needs permission; not downloaded; file details not checked".

| Priority | Condition | Summary text |
| --- | --- | --- |
| 1 | Access = Needs permission / Denied / Unknown | Access text |
| 2 | Location = Missing / Moved / Unknown | Location text |
| 3 | Identity = Mismatch / Changed | Identity text |
| 4 | Transfer = Failed / Can't connect / Downloading / Paused / Queued / Cancelled | Transfer text |
| 5 | Residency = Cloud-only / Unknown | Residency text |
| 6 | Any dimension Checking | "Checking…" |
| 7 | Otherwise | "Ready" with `checkmark.circle` |

"Ready" means "WaveWrangler can reach this file and it's on this Mac". It never means verified audio. A source **needs attention** (header counter, View › Show Only Sources Needing Attention) at priorities 1–3 and for Transfer = Failed/Can't connect.

## 4. Relink and regrant

Entry points: Source › Relink Source…, the inspector **Relink…** / **Grant Access…** buttons, the context menu, and File › Resolve Unavailable Sources… (batch).

1. **Choose.** A native open panel (single file) opens at the last known folder if it is reachable. Prompt: "Choose the recording to use for “tr2.wav”". Message: "WaveWrangler recorded: 1.21 GB, created 3 Oct 2026 at 10:02 AM, from folder ZOOM0001." Cancel changes nothing.
2. **Compare.** The Relink sheet (`ww.relink.sheet`) shows a two-column comparison table, *Recorded* vs *Chosen*, for Name, Size, Created, Modified and Kind, with a per-row result word: **Same** / **Different** / **Unknown**. The headline is one of:
   - "File details match. WaveWrangler compared file details, not audio."
   - "Some file details are different: <list>."
   - "WaveWrangler can't compare some details because <reason, e.g. the file isn't downloaded and downloads are off>."
3. **Confirm explicitly.** Buttons:
   - Match → **Use This File** (default) · **Cancel**.
   - Different/Unknown → **Use This File Anyway** · **Choose Another…** · **Cancel**, with **no default button**. A checkbox is required before **Use This File Anyway** enables: "I've checked this is the same recording".
4. **Result.** One undoable action, "Undo Relink “tr2.wav”". Identity becomes **Details match** or **Changed (accepted by you)**, and Location becomes Known. The previous location hint is kept in Details history. **The original file at any location is never moved, renamed, copied over or modified.**

Rules:
- **ST-20: No silent substitution.** A file with the same name appearing at the old path does **not** relink automatically. The source stays **Not found** with the hint "A file with the same name is at the original location — choose Relink to check it."
- **ST-21:** **Grant Access…** re-selects the *same* location. It still runs step 2. If the details differ, it behaves like Relink.
- **ST-22: Batch.** File › Resolve Unavailable Sources… lists every source needing attention in the show, grouped by episode. Each row has its remedy button. **Relink From Folder…** proposes candidates by matching name and size within a chosen folder. Each proposal is unchecked by default unless its details match. **Relink N Sources** applies only checked rows as one undoable action.
- **ST-23:** Relinking never starts a download when downloads are Off.

## 5. Library entries: reconciliation and unavailable shows

The library records each show's last-known location, name, episode summary and last-opened time. Opening a show reconciles the entry: the document is authoritative for show content, and the library is authoritative for collections, order and recents.

| Entry state | Status text · symbol | Detail-column explanation | Remedies |
| --- | --- | --- | --- |
| Available | "Available" · `checkmark.circle` | — | Open Show |
| Checking | "Checking…" · spinner | — | — |
| Not found | "Can't find show file" · `doc.questionmark` | "WaveWrangler can't find “<Show>” at <folder display name>. It may have been moved, renamed or deleted." | **Locate…** (open panel; matched by show identity inside the file, not by name) · Remove from Library… |
| Needs permission | "Needs permission" · `key.slash` | "WaveWrangler needs your permission to open this show again." | **Grant Access…** |
| Location unavailable | "Location unavailable" · `icloud.slash` | "The folder for this show isn't available right now (for example, the cloud service or drive is offline)." | Try Again |
| Newer format | "Needs newer WaveWrangler" · `lock.fill` | As D12. | Open Read-Only |
| Damaged | "Can't read show" · `exclamationmark.lock` | As D13. | Open Read-Only · Revert To… |
| Out of date | "Details out of date" · `arrow.clockwise` | "The library's details for this show will update the next time it's opened." | Open Show |

- **ST-30:** **Remove from Library…** confirms: "Remove “<Show>” from the library? The show file isn't deleted, and you can add it again with File › Open." **Remove** / **Cancel**. The action is undoable in the Library window.
- **ST-31: Rebuild Library Index…** (File › Library) shows inline progress in the Library window toolbar ("Rebuilding library index — 34 of 100 shows", determinate, with Cancel). The sheet text promises: "Your collections and their order are kept; only search and lookup information is rebuilt." Cancel leaves the previous index in use.
- **ST-32:** A library write failure shows a Library-window message bar: "Couldn't update the library: <reason>. Your shows aren't affected." It never shows as a show save failure.

### 5.1 Library location (coordinator decision, 2026-10-04)

The canonical library (collections and their order, recent items, unavailable entries, library entries) is stored at a **configurable location**. The default is **In WaveWrangler** (the app's container on this Mac). The user may choose any folder through a native open panel, including iCloud Drive, OneDrive or Dropbox folders. Shows are separate documents and never move when the library moves.

**Settings › General › Library location** (`ww.settings.libraryLocation`) is a pop-up: **In WaveWrangler** (default) · *‹current folder display name›* (when one is chosen) · **Choose Folder…**

| Location | Caption (exact) |
| --- | --- |
| In WaveWrangler | "Your library (collections, recent items and unavailable shows) is stored inside WaveWrangler on this Mac. Your shows stay wherever you saved them." |
| A chosen folder | "Your library is stored in “<folder display name>”. If this folder syncs, WaveWrangler on your other Macs can use the same library. Your shows stay wherever you saved them." |

**Changing the location (ST-33).**
1. **Choose Folder…** opens a native open panel (folders only, New Folder allowed). Prompt: "Choose a folder for your WaveWrangler library". Cancel changes nothing.
2. A confirmation sheet asks: "Move your library to “<folder>”?" Body: "WaveWrangler copies your library there, checks that the copy is complete, and then stops using the old copy. Collections, recent items and unavailable shows are all kept. The old copy stays where it is as a backup; WaveWrangler doesn't delete it." Buttons: **Move Library** (default) · **Cancel**. Choosing **In WaveWrangler** uses the same sheet with "Move your library back into WaveWrangler?".
3. Progress appears inline in Settings and in the Library window toolbar: "Moving library — copying…" then "Moving library — checking copy…" (indeterminate unless counts are known). **Cancel** is available until the switch; cancelling leaves the old location in use and unchanged.
4. **Switch only after verification.** The new copy must contain every collection, its membership and order, every recent item and every library entry, including unavailable ones. Only then does WaveWrangler switch to it and **retire** the old copy: it no longer reads or writes it and keeps it as a backup. Message bar: "Your library is now stored in “<folder>”. The previous copy was kept in <old location display name> as a backup."
5. **Failure:** "Couldn't move your library: <reason>. WaveWrangler is still using your library in <old location>; nothing was changed." The partial copy is left in place, and nothing in the old copy is touched.
6. **The folder already has a WaveWrangler library.** WaveWrangler first checks that library's state without writing anything.
   - **L1 (ready):** a sheet titled "“<folder>” already has a WaveWrangler library" says: "WaveWrangler can combine your library with the one in this folder. All collections, recent items and library entries from both are kept, including unavailable shows. Your current library is kept as a backup." Buttons: **Use That Library** (combines using the [combine rule ST-36](#combine-rule-st-36), then retires your current library and keeps it as a backup), **Choose Another Folder…** and **Cancel**. There is no default button.
   - **L2 (unreachable), L3 (needs permission) or L5 (newer format):** **Use That Library** is shown disabled, and the sheet states the reason in place of the combine text. L2: "WaveWrangler can't reach the library in this folder right now." L3: "WaveWrangler needs permission to use the library in this folder." L5: "The library in this folder was saved by a newer version of WaveWrangler, so this version can't add to it." **Choose Another Folder…** and **Cancel** remain. **Nothing is written** to the folder, and your current library stays in use unchanged. Writing into an L5 library would be a forbidden down-save.

**Library-level states** appear in a Library-window message bar (`ww.library.messageBar`) and in Settings under the Library location control. They never appear as a show save state, and shows can always still be opened with File › Open.

| ID | State | Message bar heading · symbol | Body (exact) | Actions | Library edits |
| --- | --- | --- | --- | --- | --- |
| L1 | Ready | — | — | — | Allowed |
| L2 | Unreachable (folder or provider unavailable) | "Can't reach your library" · `icloud.slash` | "WaveWrangler can't reach “<folder>”, where your library is stored. Your shows aren't affected, and you can still open them with File › Open. Library changes are kept on this Mac and saved when the folder is available again." | Try Again · Library Settings… | Allowed; queued. The pending count shows as "<n> library changes not saved yet". Retries at most every 30 s |
| L3 | Needs permission | "WaveWrangler needs permission to use your library folder" · `key.slash` | "Choose the folder again to let WaveWrangler use your library." | **Grant Access…** (open panel pre-pointed at the folder) | Queued, as L2 |
| L4 | Changed on another Mac (conflict) | "Your library was changed on another Mac" · `arrow.triangle.branch` | "Another Mac saved changes to your library while this Mac also had changes. WaveWrangler hasn't overwritten either." | **Combine (Keep Everything)** (default): combines both versions using the [combine rule ST-36](#combine-rule-st-36) · **Use Other Mac's Version** (this Mac's version is kept as a backup copy) · Cancel (stays in L4) | Read-only until resolved |
| L5 | Newer format | "Your library needs a newer WaveWrangler" · `lock.fill` | "The library in “<folder>” was saved by a newer version of WaveWrangler. You can see it, but it can't be changed here, so its newer information isn't lost. Your shows aren't affected." | Library Settings… | Read-only; no save or down-save |

#### Combine rule (ST-36)

Combining two libraries is used by **Use That Library** (step 6) and by **Combine (Keep Everything)** (L4). "Base" is the library being kept as the active one (the folder's library, or the other Mac's version), and "this Mac" is the other one. Combining never drops anything:

1. **Library entries** (including unavailable ones) are unioned by show identity, never by name or path. When both sides know the same show, the entry keeps the most recently observed location and status. The other location hint is kept in the entry's history.
2. **Recent items** are unioned by show/episode identity, sorted newest first by last-opened time.
3. **Collections** are matched by name.
   - Same name, **identical members in identical order:** keep one.
   - Same name, but members **or order** differ (order is canonical human work): keep the base collection unchanged, and add this Mac's as a separate collection named with the first free suffix: "<name> (from this Mac)", then "<name> (from this Mac 2)", "<name> (from this Mac 3)", and so on. A suffix is free when no collection in the combined library already has that exact name.
   - Collections that exist on only one side are added unchanged. If such a name collides with an existing collection, the same suffix rule applies.
4. The combined library must be written and verified as complete before it becomes active (as in ST-33 step 4). On failure, both inputs remain unchanged.
5. A message bar summarises the result: "Combined libraries: <n> collections kept as separate copies, <m> shows and <k> recent items added."

- **ST-34:** Quitting with queued library changes (L2/L3) asks: "WaveWrangler couldn't save <n> library changes. If you quit now, they'll be lost." Buttons: **Cancel** · **Quit Anyway**, with no default button [A13].
- **ST-35:** Library location changes, L4 resolution and ST-33 moves are not undoable. They are confirmed explicitly instead.

## 6. Source download setting: On and Off

Settings › Sources › **Download sources automatically** (default **On**).

| Situation | On (default) | Off |
| --- | --- | --- |
| Settings caption (exact) | "WaveWrangler asks your cloud service to download sources that aren't on this Mac so they're ready for later steps. Downloads use disk space." | "WaveWrangler uses only file names and file details. It doesn't open, read, preview or download source files. You can still download one source at a time with Source › Download." |
| Import / open episode | Cloud-only sources are queued (Transfer = Queued → Downloading) | Residency shown; Transfer = "Downloads are off"; **zero** content/hash/header/preview/decode/download requests |
| Explicit Source › Download | Downloads that source | Downloads only that source (explicit user action) |
| Relink / Grant Access | No download as a side effect | No download as a side effect |
| Turning On → Off | Queued downloads are cancelled. In-progress downloads are cancelled where possible; otherwise the row reads "Your cloud service may finish this download on its own". Downloaded files stay. | — |
| Turning Off → On | — | Cloud-only sources in **open** shows are queued; closed shows queue when next opened |

## 7. Announcements

| Event | Announcement text | Priority |
| --- | --- | --- |
| Save completes after an explicit ⌘S | "Saved" | low |
| Any save failure (D5, D7–D9) | "Couldn't save “<Show>”. <short reason>." | high |
| Conflict detected (D6) | "“<Show>” was changed somewhere else. Your changes are kept." | high |
| Library state L2–L5 appears; library move completes or fails | Message bar heading | default |
| Automatic retry succeeds after D7 | "Saved" | low |
| Recovered / read-only on open (D11–D13, D15) | Message bar heading | default |
| Download progress (focused source only) | Start; then at 25%, 50% and 75% at most every 10 s; completion "Downloaded tr2.wav" | low |
| Download failure | "Download failed for tr2.wav: <reason>" | default |
| Import complete | "Imported 9 sources" | default |
| Blocked destination selected | Panel heading | default |
| Undo/Redo | "Undid <action>" / "Redid <action>" | default |

Autosaves that succeed silently are **not** announced. Background state changes for unfocused sources are not announced individually. The header counter's value change is announced once: "3 sources need attention".
