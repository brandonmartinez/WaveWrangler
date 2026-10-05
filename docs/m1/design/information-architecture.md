# M1 information architecture

**Owner:** Design · **Status:** specification for M1 implementation. It is **not implemented or tested**. · **Refs:** [WW-011 (#2)](https://github.com/brandonmartinez/WaveWrangler/issues/2), [WW-012 (#9)](https://github.com/brandonmartinez/WaveWrangler/issues/9), [WW-007 (#8)](https://github.com/brandonmartinez/WaveWrangler/issues/8), [WW-013 (#12)](https://github.com/brandonmartinez/WaveWrangler/issues/12); evolves the documentary [WW-004 specification](../../research/foundation-spikes.md#ww-004-documentary-native-m1-specification).

Companion documents: [states and recovery](states-and-recovery.md) · [commands and keyboard](commands-keyboard.md) · [accessibility acceptance](accessibility-acceptance.md) · [sources](sources.md).

Decisions are numbered `IA-nn` so Mac UI sessions, reviewers and tests can reference them. Apple guidance is cited as `[A#]` from [sources.md](sources.md).

## 1. Vocabulary the user sees

Use these exact nouns in UI text, menus, VoiceOver labels and help. Do not use internal terms (bookmark, scope, residency, manifest, revision, index) in primary UI. They may appear only in a "Details" disclosure.

| User-facing term | Meaning (product model) | Notes |
| --- | --- | --- |
| **Library** | App-level, durable organisation of shows, collections, recent and unavailable entries. | Canonical semantic data (collections, membership, order) is never treated as a disposable cache; the lookup index is rebuildable. |
| **Show** | One durable project document per podcast; contains many episodes. | Canonical show document lives where the user chose, including iCloud Drive/OneDrive/Dropbox folders. |
| **Episode** | One recording/edit/export unit inside a show. | Ordered by the user. |
| **Collection** | User-named group of shows and episodes in the library. | Membership is a reference; removing from a collection never deletes anything. |
| **Source** | One referenced original recording file. WaveWrangler never moves, renames, edits or deletes it. | Shown by file name, but **file name and path are never identity** (see [states](states-and-recovery.md#3-source-states-five-independent-dimensions)). |
| **Recorder Group** | Sources recorded by one device/clock. | Clock group ≠ epoch ≠ channel ≠ speaker. |
| **Epoch** | Whole number (1, 2, …) marking a restart of that recorder's clock within the group. | Help text: "Start a new epoch when the recorder was stopped and started again, so its clock restarted." |
| **Channel** | Which channel of a source carries a speaker. | Channel count is **Unknown** in M1 unless safe file-system metadata supplies it. A user-entered channel is shown as *not checked against the file*. |
| **Speaker** | A person in the episode; "Unassigned" is valid. | Each speaker has at most one **Primary** source/channel and any number of **Backups**. |
| **Suggestion** | A proposed grouping or speaker assignment derived from folder/file names. | Never applied until the user confirms it. |

## 2. Windows and the document model

| Window | Kind | Count | Purpose |
| --- | --- | --- | --- |
| **Library** | App window (not a document) | Exactly one; Window › Library (⇧⌘L) | Find, organise and open shows; see unavailable entries and their remedies. |
| **Show window** | `NSDocument` window hosting SwiftUI | One per open show by default; more via File › New Window for “Show” | Edit one show: its episodes, sources, groups, speakers and metadata. |
| **Settings** | App settings window | One; ⌘, | General (Autosave, Text Size) and Sources (Download sources automatically). [A12] |
| Sheets and panels | Modal to one window | — | Native Open/Save panels, Import Review, Relink, Resolve Conflict, Recover, close-with-unsaved-changes. |

- **IA-01: One show = one document.** Opening a show that is already open brings its frontmost window forward. It never opens a second document instance.
- **IA-02: Multiple windows per show.** File › New Window for “Show” opens another window on the same document. Windows share the document, its undo history and its save state. Each window keeps its own **episode selection, destination, sidebar/inspector visibility, scroll position and focus**. Closing one window does not close the show unless it is the show's last window. File › Close Show (⇧⌘W) closes every window of that show [A6, A11].
- **IA-03: Library is not a document.** Its edits (collections, order, removal from library) use the Library window's own undo history. They never mark a show as edited.
- **IA-04: Location first.** File › New Show asks for a name and location before the show exists (native save panel). There are no "Untitled" shows. This keeps the canonical location explicit for cloud folders and prevents a show from existing only in an autosave area.
- **IA-05: Launch behaviour.** Restore the windows that were open at quit (state restoration). If none were open, show the Library window. Never show an alert at launch [A13]. Recovery and conflict information appears in the affected show window's message bar (§6).
- **IA-06: Window titles.** The Library window is titled "Library", not the app name [A22]. A show window is titled with the show name; the subtitle is the selected episode's title. The standard "— Edited" title suffix follows [states §2](states-and-recovery.md#2-document-save-states).

## 3. Library window

The Library window uses a three-column split view [A18]: sidebar → entry list → entry detail. The sidebar has **two levels** (section → item) [A3]. The show → episode hierarchy appears in the content and detail columns, never as a third sidebar level.

```
┌─ Library ──────────────────────────────────────────────────────────────────────────────────────┐
│ ◧  Library                                            [New Show]  [Open…]   🔍 Search          │
├──────────────────────┬───────────────────────────────────────────┬─────────────────────────────┤
│ LIBRARY              │ Shows (24)                                 │ The Daily Wrangle           │
│  📚 Shows            │ Name               Episodes Location   St. │ iCloud Drive › Podcasts     │
│  🕘 Recent           │ The Daily Wrangle      12  iCloud…   ✓ OK  │ Last opened today 9:40 PM   │
│  ⚠ Unavailable  (3)  │ Garage Talk             4  OneDrive  ⚠ No  │                             │
│ COLLECTIONS       +  │                                 permission │ Episodes (as of last open)  │
│  ▭ In Progress       │ Old Show                9  Dropbox   🔒 Re │  12 Interview with Ana      │
│  ▭ Season 2          │                                  ad-only   │  11 Listener Roundup        │
│                      │                                            │                             │
│                      │                                            │ [Open Show]  [Open Episode] │
└──────────────────────┴───────────────────────────────────────────┴─────────────────────────────┘
```

### 3.1 Library sidebar items

| Section | Item | Symbol | Content column shows | VoiceOver label / value |
| --- | --- | --- | --- | --- |
| Library | **Shows** | `books.vertical` | All shows known to the library | "Shows" / "24 shows" |
| Library | **Recent** | `clock` | Recently opened shows and episodes, newest first | "Recent" / "8 items" |
| Library | **Unavailable** | `exclamationmark.triangle` | Entries whose show file could not be opened at last check, with the reason | "Unavailable" / "3 items need attention" (or "None") |
| Collections | *each collection* | `rectangle.stack` | Members (shows and episodes), in user order | "<name>, collection" / "<n> items" |

- **IA-07:** The **New Collection** affordance is a "+" button in the Collections section header and File › Library › New Collection…. It is never placed at the bottom of the sidebar [A3].
- **IA-08:** Unavailable entries also stay in Shows/Recent/Collections, with their status shown. The Unavailable item is a filtered view, not a move. The library never auto-removes an entry.
- **IA-09:** The "(3)" count is text, not a coloured dot. The item stays visible when the count is zero (value "None").

### 3.2 Entry list (content column)

A native table (`Table`/`NSTableView`) with sortable columns: **Name**, **Kind** (Recent and collections only: Show/Episode), **Episodes** (last-known count), **Location** (provider and folder display name, never a full path [A11]), **Last Opened**, **Status** (text + symbol). Return or ⌘↓ opens the selection. Multi-selection supports Add to Collection and Remove from Library.

### 3.3 Entry detail (detail column)

This column shows the show name, display location, last-opened time, and the episode list **labelled "as of last open"**. Library data reflects the last reconciliation, not live document truth. It also shows the status with its full reason and remedy buttons from [states §5](states-and-recovery.md#5-library-entries-reconciliation-and-unavailable-shows), plus the buttons **Open Show** (default), **Open Episode** (when an episode is selected) and **Show in Finder**.

## 4. Show window

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ◧  The Daily Wrangle — Edited      [ Setup | Alignment | Review | Export ]   ✎ Edited ▾      ⓘ   │
│    Interview with Ana                                                                            │
├────────────────┬──────────────────────────────────────────────────────────────┬──────────────────┤
│ EPISODES    +  │ ┌ message bar (only when needed, §6) ─────────────────────────┐ │ INSPECTOR        │
│  12 Interview… │ └─────────────────────────────────────────────────────────────┘ │ Source           │
│  11 Listener…  │ Sources  14 · 2 need attention            [Import Sources…]  │ tr2.wav          │
│  10 Live from… │  Name             Epoch  Ch   Speaker  Role     Status        │ Recorder group   │
│ SHOW           │  ▾ Zoom H6 — recorder group · 3 sources                      │ [Zoom H6     ▾]  │
│  Show Info     │     tr1.wav         1     1   Ana      Primary  ✓ On Mac     │ Epoch  [ 1 ]⇅    │
│                │     tr2.wav         1     2   Ben      Primary  ☁ Not downl… │ Channel[ 2 ]⇅    │
│                │     tr3.wav         1     ?   —        —        ✓ On Mac     │ Speaker[ Ben ▾]  │
│                │  ▾ Ana's laptop — recorder group · 1 source                  │ Role   (•)Primary│
│                │     ana-zoom.m4a    1     ?   Ana      Backup   🔑 Needs perm │        ( )Backup │
│                │  ▾ Ungrouped · 2 sources                                     │ ── Availability ─│
│                │     intro.wav       —     ?   —        —        ⚠ Not found  │ Location  Known  │
│                │ ──────────────────────────────────────────────────────────── │ Access    Granted│
│                │ Speakers  3                                   [New Speaker…] │ On Mac    No …   │
│                │  Speaker  Primary                Backups  Status             │ Download  42%    │
│                │  Ana      tr1.wav · channel 1      1      ✓ Primary chosen   │ Identity  Not ch │
│                │  Ben      tr2.wav · channel 2      0      ✓ Primary chosen   │ [Pause] [Cancel] │
│                │  Guest    — No primary —           0      ! Choose primary   │ [Relink…]        │
└────────────────┴──────────────────────────────────────────────────────────────┴──────────────────┘
```

### 4.1 Show sidebar (two levels)

| Section | Rows | Symbol | Behaviour |
| --- | --- | --- | --- |
| **Episodes** | One row per episode, user order, "<number> <title>" | `music.mic` | Selecting an episode changes the content; the destination is kept. The "+" button in the section header = File › New Episode. |
| **Show** | **Show Info** | `info.circle` | Show-level metadata (title, description, notes) and the show's location/save details. |

- **IA-10:** Episode reorder uses Edit › Move Up/Move Down (⌥⌘↑/⌥⌘↓). Drag is optional and undoable [A7].
- **IA-11:** When no episode exists, the content shows the empty state "No episodes yet" with a **New Episode** button.

### 4.2 Destinations

Destinations appear as a segmented control in the toolbar centre and as View menu items ⌘1–⌘4. They are revisitable workspaces, not wizard steps. M1 implements **Setup** only.

| Destination | M1 state | Content | Toolbar segment VoiceOver |
| --- | --- | --- | --- |
| **Setup** | Available | Sources (grouped) + Speakers; episode metadata in inspector | "Setup, selected" / tab 1 of 4 |
| **Alignment** | **Not available in this version** (M2) | Blocked panel (below) | "Alignment" / "Not available in this version" |
| **Review** | **Not available in this version** (M3) | Blocked panel | "Review" / "Not available in this version" |
| **Export** | **Not available in this version** (M4) | Blocked panel | "Export" / "Not available in this version" |

- **IA-12: Blocked, not hidden, not dead.** Later destinations are **visible, focusable and selectable**. Selecting one shows a blocked panel with its reason and the way forward, rather than a dimmed control with no explanation. Each segment shows a small `lock.fill` symbol plus the word "Later" in its help tag. Its accessibility value is "Not available in this version". Commands that act *inside* those destinations do not exist in M1 menus.
- Blocked panel wording (heading role; the text is the full accessible content):

| Destination | Heading | Body | Button |
| --- | --- | --- | --- |
| Alignment | "Alignment isn't available yet" | "Lining up recorder groups comes in a later version of WaveWrangler. The recorder groups, epochs, channels and speakers you set up now will carry forward. WaveWrangler hasn't read or analysed any audio." | **Go to Setup** (⌘1) |
| Review | "Review isn't available yet" | "Reviewing speech edits comes in a later version of WaveWrangler. Your episode setup will carry forward." | **Go to Setup** |
| Export | "Export isn't available yet" | "Exporting cleaned speaker tracks comes in a later version of WaveWrangler. Nothing has been exported." | **Go to Setup** |

- **IA-13:** Selecting a blocked destination never moves keyboard focus by itself. Focus stays on the segmented control; the panel is announced as a layout change [A2, A9].

### 4.3 Setup content

1. **Sources** (heading). A native outline table (`NSOutlineView` or SwiftUI `Table` with disclosure rows). Hierarchy: **Recorder Group** row → **Source** rows → optional **Channel assignment** rows (only when a source carries more than one speaker). An **Ungrouped** pseudo-group always exists. Columns: Name, Epoch, Ch(annel), Speaker, Role, Status. A missing value displays "—" with the VoiceOver value "none". An unknown value displays "?" with the VoiceOver value "unknown".
   - Header line: "Sources 14 · 2 need attention". "2 need attention" is a button that toggles View › Show Only Sources Needing Attention.
   - Group rows read "<name> — recorder group · <n> sources". Editing the group name is undoable.
2. **Speakers** (heading). A table with columns Speaker, Primary, Backups (count; the inspector lists them), Status ("Primary chosen" / "Choose primary" / "Primary unavailable — <reason>").
3. The two tables are stacked vertically in a resizable split. Each is its own focus group (Tab moves between them) [A9].

### 4.4 Inspector (trailing, ⌃⌘I)

The inspector is selection-driven, not focus-driven. It shows the inspector for the most recent selection in the focused table, or the episode when nothing is selected. Its heading names the kind: **Episode**, **Recorder Group**, **Source**, **Speaker**, or **Show** (from Show Info). [A29, A33]

| Inspector | Fields and actions (every pointer action has a keyboard path; see [commands](commands-keyboard.md)) |
| --- | --- |
| Episode | Title, Number (numeric field), Season (numeric, optional), Recording date (date field), Notes. Collections membership (Add to Collection…). |
| Recorder Group | Name; sources count; **New Epoch for Selected Sources** action; group notes. |
| Source | Name (read-only, the file's current display name); Recorder group (pop-up incl. **New Recorder Group…** and **Ungrouped**); Epoch (numeric field + stepper, ≥ 1); Channel (numeric field + stepper, ≥ 1, or **Unknown**; caption "Not checked against the file"); Speaker (pop-up incl. **New Speaker…** and **Unassigned**); Role (radio: **Primary** / **Backup**, disabled with reason when no speaker); **Availability** section showing all five state rows ([states §3](states-and-recovery.md#3-source-states-five-independent-dimensions)) with their remedy buttons; **Details** disclosure (last known location display, recorded file details, last checked time). |
| Speaker | Name; Primary (pop-up listing that speaker's assigned source/channels plus **None**); Backups list with **Make Primary** per row; Notes. |
| Show | Title, description, notes; location display; save status details (same content as the save-status popover). |

## 5. Import review (messy folder)

File › Import Sources… (⇧⌘I) opens the native open panel (files and folders, multiple selection). The panel's prompt is "Choose recordings or folders to add to “<Episode>”". Its accessory text reads: "WaveWrangler adds references to these files. It never moves, renames or changes them." Confirming the panel opens the **Import Review** sheet:

```
┌ Import 9 Sources into “Interview with Ana” ────────────────────────────────────────────────────┐
│ From: ~/…/Ana Interview (2 folders, 11 files; 2 not recordings, skipped)                       │
│ Suggestions are based only on folder and file names. Review them before importing.             │
│ [✓] Include  Name            Folder        Recorder group (suggested)   Speaker (suggested)    │
│ [✓]          tr1.wav         ZOOM0001      Zoom H6  ◌ suggested ▾       Ana ◌ suggested ▾       │
│ [✓]          tr2.wav         ZOOM0001      Zoom H6  ◌ suggested ▾       — ▾                     │
│ [✓]          ana-zoom.m4a    Ana           Ana      ◌ suggested ▾       Ana ◌ suggested ▾       │
│ [ ]          notes.txt       —             not a recording (skipped)                           │
│ ────────────────────────────────────────────────────────────────────────────────────────────── │
│ ☁ 3 files aren't downloaded. Downloads are On: they'll download after import. [Change…]         │
│                         [Accept All Suggestions] [Clear Suggestions]   [Cancel]  [Import 9]     │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **IA-14: Metadata-only discovery.** Enumeration uses file-system names, folder structure, type-by-extension, size and dates only. It never opens, reads headers of, previews, hashes or downloads files [invariant]. Files recognised only by extension show the caption "Type from file name".
- **IA-15: Suggestions are unconfirmed.** Each suggested value shows `circle.dashed` plus the word "suggested", with a reason in the help tag and the VoiceOver hint (for example "Suggested because the files share folder ZOOM0001"). Editing a pop-up or choosing **Accept All Suggestions** confirms values; confirmed values show plain text. On **Import**, unconfirmed suggestions are discarded (those sources land in **Ungrouped/Unassigned**). This keeps suggestions from silently becoming facts. **Import** reports this in its confirmation line: "2 suggestions weren't accepted and won't be applied."
- **IA-16:** **Cancel** changes nothing. **Import N** is the default button and performs one undoable action ("Undo Import 9 Sources"). Afterwards the imported rows are selected and scrolled into view, with no unsolicited focus jump outside the Sources table [A5, A9].
- **IA-17:** The download line reflects the current setting (On: "…they'll download after import."; Off: "Downloads are Off: WaveWrangler will use file details only and won't download them."). **Change…** opens Settings › Sources.
- **IA-18: Duplicates.** If a chosen file is already referenced in the episode, it shows "Already in this episode" and is excluded by default. A *same-named* different file is **not** a duplicate. Name is not identity, so both are listed.

Suggestions after import (Episode › Suggest Groups…) use the same review sheet, limited to existing sources.

## 6. Where status lives

| Status | Primary location | Secondary | Never |
| --- | --- | --- | --- |
| Document save state | Toolbar trailing **save-status item** (symbol + short text, opens a popover with details and actions) | Title "— Edited" suffix; close-button dot and Window-menu dot **only when Autosave is Off** [A4]; Show Info inspector | Bottom bar [A10]; colour-only dot while autosave is On |
| Recovery / conflict / read-only / migration | **Message bar** at the top of the show window content: heading + body + buttons. Persistent until resolved or closed by the user; **not time-boxed** [A1] | Save-status popover | Launch-time alert [A13] |
| Source states | Sources table Status column (summary text + symbol) | Inspector Availability section (all five dimensions, always); "need attention" counter | A single generic "Offline" state |
| Library entry state | Entry list Status column + detail column remedies | Unavailable sidebar count | Removal of the entry |
| Long work (download, index rebuild, import scan) | Inline in the row/item it concerns (bar or spinner per [A8]) | Activity popover from the save-status area listing active operations with Cancel | Modal progress sheet for background work |

## 7. Accessibility identifiers (for XCUITest and AX-tree checks)

Stable identifiers do not change with localisation. Pattern: `ww.<window>.<region>.<element>[.<logicalID>]`. Row identifiers use the **logical ID**, never a file name or path.

| Identifier | Element |
| --- | --- |
| `ww.library.sidebar` / `ww.library.sidebar.shows` / `.recent` / `.unavailable` / `.collection.<id>` | Library sidebar and items |
| `ww.library.entries` / `ww.library.entry.<showID>` | Entry table / row |
| `ww.library.detail.open` | Open Show button |
| `ww.show.sidebar.episodes` / `ww.show.sidebar.episode.<episodeID>` / `ww.show.sidebar.showInfo` | Show sidebar |
| `ww.show.destination` / `ww.show.destination.setup` / `.alignment` / `.review` / `.export` | Destination control and segments |
| `ww.show.blocked.<destination>` | Blocked panel |
| `ww.show.saveStatus` | Save-status toolbar item |
| `ww.show.messageBar` | Message bar container |
| `ww.setup.sources` / `ww.setup.source.<sourceID>` / `ww.setup.group.<groupID>` | Sources outline and rows |
| `ww.setup.source.<sourceID>.status` | Status cell |
| `ww.setup.speakers` / `ww.setup.speaker.<speakerID>` | Speakers table and rows |
| `ww.inspector` / `ww.inspector.source.group` / `.epoch` / `.channel` / `.speaker` / `.role` / `.location` / `.access` / `.residency` / `.transfer` / `.identity` | Inspector fields |
| `ww.import.review` / `ww.import.row.<n>` / `ww.import.confirm` | Import Review sheet |
| `ww.relink.sheet` / `ww.relink.compare` / `ww.relink.confirm` | Relink sheet |
| `ww.settings.autosave` / `ww.settings.downloadSources` / `ww.settings.textSize` | Settings controls |

## 8. Scale and responsiveness implications (WW-007)

- The library must stay usable with **100 shows / 1,000 source references** (the WW-007 synthetic scale). Lists are virtualised native tables; sorting and filtering never block the main thread.
- **IA-19: No provider I/O on the main thread.** Any state that needs file-system or provider observation renders **"Checking…"** (indeterminate, inline) until observed. Such state is never rendered as a guessed value. Opening a show displays document content first; source availability fills in asynchronously.
- These shapes keep the provisional WW-007 budgets (p95 open < 1 s, interaction < 100 ms on the claimed host) achievable. This spec does **not** claim the budgets are met.

## 9. State restoration

Restore per window: selected episode, destination, sidebar and inspector visibility, split positions, table sort, scroll and selection. If a restored episode no longer exists, select the first episode. The message bar then reads "“<Episode>” is no longer in this show." Restoration never auto-retries a failed save. It never downloads sources unless "Download sources automatically" is On.

## 10. Open questions (for Lead/Mac; Design recommendation in bold)

1. Collections containing **episodes** as well as shows: **recommended for M1** (Recent already mixes kinds). Fallback: shows only, if Mac's library schema can't carry episode references in M1.
2. Per-show override of "Download sources automatically": **not in M1**. The Show inspector displays the effective app setting with a **Change in Settings…** link.
3. The macOS system setting "Ask to keep changes when closing documents" [A4] versus WaveWrangler's own Autosave setting: **WaveWrangler's setting is authoritative for WaveWrangler UI**. Mac to confirm how AppKit close/quit alerts behave with both settings [A28].
