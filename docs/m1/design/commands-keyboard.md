# M1 commands, menus and keyboard

**Owner:** Design · **Status:** specification for M1 implementation. It is **not implemented or tested**. · **Refs:** [WW-011 (#2)](https://github.com/brandonmartinez/WaveWrangler/issues/2), [WW-012 (#9)](https://github.com/brandonmartinez/WaveWrangler/issues/9), [WW-007 (#8)](https://github.com/brandonmartinez/WaveWrangler/issues/8).

Companion documents: [information architecture](information-architecture.md) · [states and recovery](states-and-recovery.md) · [accessibility acceptance](accessibility-acceptance.md) · [sources](sources.md).

## 1. Rules

- **CMD-01:** Every command is in the menu bar. Toolbars, context menus, inspector buttons and drag are **additional** paths, never the only one [A11, A14].
- **CMD-02:** Menu-bar items are always present. Unavailable items are dimmed, not hidden, and menus and submenus stay openable [A11, A15]. Because a dimmed item can't explain itself, every state that disables a command also shows its reason in the window (message bar, inspector or blocked panel).
- **CMD-03:** Context menus show only the applicable items, hide unavailable ones, have at most three groups and display no shortcuts [A14].
- **CMD-04:** Standard shortcuts keep their standard meaning. Custom shortcuts use ⌘ first, then ⇧, use ⌥ sparingly and do not add new ⌃ bindings [A6]. Two exceptions come from framework-provided commands: ⌃⌘I (inspector) [A29] and ⌃⌘S (sidebar, **unverified**, see A30).
- **CMD-05:** An ellipsis (…) marks commands that need more input [A11]. Show/hide item titles reflect the current state [A11].
- **CMD-06:** Text fields keep every standard editing shortcut. No WaveWrangler shortcut fires while a text field has focus, unless it includes ⌘ [A6].
- **CMD-07:** A required command is never available **only** as an Option-key alternate [A11]. Save As… is therefore a visible item.

## 2. Menu bar

"Writable show" means a show window is key and its document is not read-only ([states D12–D16](states-and-recovery.md#2-document-save-states)).

### WaveWrangler (app menu)

| Item | Shortcut | Notes |
| --- | --- | --- |
| About WaveWrangler | — | |
| Settings… | ⌘, | Opens the last-used pane [A12] |
| Services ▸ · Hide WaveWrangler (⌘H) · Hide Others (⌥⌘H) · Show All | standard | |
| Quit WaveWrangler | ⌘Q | Unsaved shows trigger [close rules](states-and-recovery.md#23-close-quit-and-revert) |

### File

| Item | Shortcut | Enabled when | Notes |
| --- | --- | --- | --- |
| New Show… | ⌘N | Always | Save panel: name + location first (IA-04). Accessory text: "Autosave is On. You can change this in Settings." (Off: "Autosave is Off. Use File › Save to save changes.") |
| New Episode | ⇧⌘N | Writable show | Adds "Episode <n+1>", selects it in the sidebar and starts inline rename. One undo: "Undo New Episode" |
| New Window for “<Show>” | — | A show window is key | IA-02 |
| Open… | ⌘O | Always | Native open panel |
| Open Recent ▸ | — | Always | Show names only, most recent first; Clear Menu [A11] |
| Close | ⌘W | Any window | Closes the window (the show stays open if it has other windows) |
| Close Show | ⇧⌘W | Show window key | Closes every window of that show [A6] |
| Save | ⌘S | Show window key, not read-only | Always available; also works with Autosave On (forces D4 → D1) |
| Duplicate | ⇧⌘S | Show window key, not D12 | New show copy; asks for name/location; **never copies sources** |
| Save As… | ⌥⇧⌘S | Show window key, not D12 | Visible item (CMD-07). Saves this window's content to a new location; the original stays as last saved |
| Rename… · Move To… | — | Writable show | Native document rename/move; title updates |
| Revert To ▸ | — | Show window key, not D12 | Last Saved Version · recent versions · Browse Saved Versions… ([states §2.3](states-and-recovery.md#23-close-quit-and-revert)) |
| Import Sources… | ⇧⌘I | Writable show with an episode selected | Opens the [Import Review](information-architecture.md#5-import-review-messy-folder) flow |
| Relink Source… | — | One source selected | [Relink flow](states-and-recovery.md#4-relink-and-regrant) |
| Resolve Unavailable Sources… | — | Show window key | Batch sheet (ST-22) |
| Library ▸ | — | Always | New Collection… · Add to Collection ▸ · Remove from Collection · Remove from Library… · Locate Show… · Rebuild Library Index… |
| Show in Finder | — | Show window key | Reveals the show file (never a source write) |

### Edit

| Item | Shortcut | Notes |
| --- | --- | --- |
| Undo *‹action›* | ⌘Z | Title names the action (§3) [A5, A11] |
| Redo *‹action›* | ⇧⌘Z | |
| Cut · Copy · Paste | ⌘X · ⌘C · ⌘V | Text fields: standard. Rows: Copy copies display names as text; Cut and Paste are disabled for rows in M1 |
| Delete | ⌫ | Acts on the focused list: Delete Episode… / Remove Source from Episode… / Delete Speaker… / Remove from Collection / Remove from Library… (confirmation wording §6) |
| Select All | ⌘A | |
| Move Up · Move Down | ⌥⌘↑ · ⌥⌘↓ | Title adapts: "Move Episode Up", "Move Source Up", "Move Speaker Up", "Move Collection Up". Disabled at the list edge |
| Find ▸ Find… | ⌘F | Focuses the window's search/filter field |
| (system) Start Dictation, Emoji & Symbols | — | Added automatically [A11] |

### View

| Item | Shortcut | Notes |
| --- | --- | --- |
| Show/Hide Toolbar · Customize Toolbar… | ⌥⌘T · — | |
| Show/Hide Sidebar | ⌃⌘S (unverified) | The sidebar is visible by default [A3] |
| Show/Hide Inspector | ⌃⌘I | [A29] |
| Show Save Status | — | Opens the save-status popover with focus inside it (keyboard path to [states §2](states-and-recovery.md#2-document-save-states)) |
| Setup · Alignment · Review · Export | ⌘1 · ⌘2 · ⌘3 · ⌘4 | Always enabled in show windows; later ones show blocked panels (IA-12). Checkmark on the current item |
| Show Only Sources Needing Attention | — | Checkmark toggle |
| Sort Sources By ▸ | — | Manual Order (default) · Name · Epoch · Channel · Speaker · Status |
| Text Size ▸ Bigger · Smaller · Actual Size | ⌘+ (⇧⌘=) · ⌘− · ⌘0 | 100%–200% in 25% steps (§7) |
| Enter/Exit Full Screen | ⌃⌘F | standard |

### Episode

The Episode menu is ordered more general than the Source menu, mirroring the hierarchy [A11].

| Item | Shortcut | Notes |
| --- | --- | --- |
| Episode Info | ⌘I | Shows the inspector with the Episode heading and focuses Title (a user-initiated focus move) [A6] |
| Rename Episode | — | Inline rename in the sidebar (Return does the same when the episode row is focused) |
| Duplicate Episode | — | Copies setup (references, groups, speakers, assignments); never copies source files. "Undo Duplicate Episode" |
| New Recorder Group… | — | Name sheet; "Undo New Recorder Group" |
| New Speaker… | — | Name sheet; "Undo New Speaker" |
| Suggest Groups… | — | Import Review sheet in suggestion-only mode (IA-15) |
| Add to Collection ▸ | — | Collections list · New Collection… |
| Delete Episode… | — | Same as Edit › Delete on an episode |

### Source

Source items act on the selected source rows in the Sources table. With multiple selection they apply to all the selected rows.

| Item | Notes |
| --- | --- |
| Assign to Recorder Group ▸ | Each group · Ungrouped · New Recorder Group… — "Undo Assign to Group “Zoom H6”" |
| Set Epoch… | Numeric sheet (whole number ≥ 1; Return applies). "Undo Set Epoch" |
| Start New Epoch | Increments the epoch of the selected sources by 1 |
| Set Channel… | Numeric sheet (whole number ≥ 1, or **Unknown** checkbox). Caption "WaveWrangler doesn't check this against the file in this version." "Undo Set Channel" |
| Assign Speaker ▸ | Each speaker · Unassigned · New Speaker… — "Undo Assign Speaker “Ana”" |
| Use as Primary | Enabled when exactly one source/channel with a speaker is selected. Replaces that speaker's previous primary, which becomes a Backup. "Undo Change Primary for “Ana”" |
| Use as Backup | "Undo Change Backup for “Ana”" |
| Download · Pause Download · Resume Download · Cancel Download · Retry Download | Shown per [Transfer states](states-and-recovery.md#34-transfer--wavewranglers-download-request). Pause and Resume appear only where pausing is supported (dimmed otherwise) |
| Relink Source… · Grant Access… · Review Changed File… · Check File Details | [Relink and regrant](states-and-recovery.md#4-relink-and-regrant) |
| Show Source in Finder | Reveals the original; never changes it |
| Remove from Episode… | Same as Edit › Delete on a source |

### Window

| Item | Shortcut | Notes |
| --- | --- | --- |
| Minimize · Zoom | ⌘M · — | Required for Full Keyboard Access [A11] |
| Library | ⇧⌘L | Brings the Library window forward or opens it |
| Bring All to Front | — | |
| *open windows, alphabetical* | — | A dot appears next to a show **only** when Autosave is Off and it has unsaved changes [A4] |

### Help

WaveWrangler Help (⌘?) · Keyboard Shortcuts · About Source States (opens help for [states §3](states-and-recovery.md#3-source-states-five-independent-dimensions)).

### Custom shortcut register

⇧⌘N New Episode · ⇧⌘I Import Sources… · ⌥⇧⌘S Save As… · ⇧⌘L Library · ⌘1–⌘4 destinations · ⌥⌘↑/⌥⌘↓ Move Up/Down · ⌘+/⌘−/⌘0 Text Size · ⌘I Episode Info (standard "Info"). None of these appears in the standard table [A6] with a conflicting meaning. ⇧⌘S keeps its standard meaning (Duplicate/Save As). Mac's menu tests must assert this register (see [acceptance §4](accessibility-acceptance.md#4-automated-structural-checks)).

## 3. Named undo actions

Each undoable action registers exactly this name. After undo or redo, the affected item is selected and scrolled into view, and the result is announced ("Undid Assign to Group") [A5]. Focus stays in the list where the user is working.

| Scope | Undo names |
| --- | --- |
| Show document | New Episode · Rename Episode · Duplicate Episode · Delete Episode · Move Episode · Edit Episode Info (one entry per committed field edit, e.g. "Undo Edit Title") · Edit Show Info · Import *n* Sources · Remove Source · Assign to Group “*g*” · New Recorder Group · Rename Recorder Group · Set Epoch · Start New Epoch · Set Channel · Assign Speaker “*s*” · New Speaker · Rename Speaker · Delete Speaker · Change Primary for “*s*” · Change Backup for “*s*” · Move Source · Relink “*file*” · Accept New Location · Accept Changed File · Revert to Version |
| Library window | New Collection · Rename Collection · Delete Collection · Add to Collection · Remove from Collection · Move Collection · Remove from Library |
| Not undoable | Save, Duplicate, Save As, Settings changes, downloads, Grant Access (permission), Rebuild Library Index |

Undo survives saves within a session (`NSDocument`/`UndoManager`). Undo history is per document and shared across that show's windows (IA-02).

## 4. Focus and keyboard behaviour

### 4.1 Focus order (Tab / ⇧Tab moves between groups; arrows move within a group) [A9]

| Window | Order | Initial focus |
| --- | --- | --- |
| Library | Sidebar → entry list → detail (Open Show, Open Episode, remedy buttons) | Restored. First launch: sidebar, "Shows" selected |
| Show | Sidebar (Episodes, Show Info) → message bar buttons (if present) → Sources table → Speakers table → inspector fields in visual order | Restored. Otherwise the episode list, current episode selected |
| Sheets (Import Review, Relink, Conflict, Revert, numeric sheets) | First input/table → secondary buttons → default button | First input. On dismissal, focus returns to the control that opened the sheet |
| Settings | Pane toolbar (⌃F5) → controls top to bottom | First control of the restored pane |
| Popovers (save status) | Content text (static) → action buttons | First action button; Esc closes and returns focus to the save-status item |

Toolbar items are reached through Full Keyboard Access (⌃F5) [A6]. Every toolbar command also has a menu item, so the toolbar is never required. VoiceOver reading order matches the focus order: sidebar → content → inspector. The message bar is announced before the tables (use `accessibilitySortPriority` [A32] if the layout differs).

### 4.2 In lists and tables

| Key | Library entries | Episode sidebar | Sources / Speakers tables | Import Review table |
| --- | --- | --- | --- | --- |
| ↑ ↓ | Move selection | Move selection (content follows) | Move selection; ← → collapse/expand group rows | Move selection |
| Return | Open | Rename | Focus the inspector's first editable field | Toggle Include |
| Space | Quick Look is **not** used (it would read content) | — | — | Toggle Include |
| ⌫ | Remove from Library… | Delete Episode… | Remove Source… / Delete Speaker… | Exclude row |
| ⌘↓ | Open | — | — | — |
| Type letters | Type-select by name | Type-select | Type-select | Type-select |
| ⇧↑/⇧↓, ⌘-click equivalent ⌘A | Extend selection | — (single selection) | Extend selection | Extend selection |

No list shortcut moves focus out of its list without a user command. When a selected row disappears (for example after removal), selection moves to the next row, or the previous one at the end, and is announced. Focus stays in the list [A9].

## 5. Non-drag alternatives

| Pointer/drag gesture (optional) | Required non-drag path |
| --- | --- |
| Drag a source onto a recorder group | Source › Assign to Recorder Group ▸; inspector "Recorder group" pop-up; context menu |
| Drag to reorder episodes/sources/speakers/collections | Edit › Move Up/Move Down (⌥⌘↑/⌥⌘↓) |
| Drag a source onto a speaker | Source › Assign Speaker ▸; inspector "Speaker" pop-up |
| Drag a show/episode into a collection | File › Library › Add to Collection ▸; Episode › Add to Collection ▸; context menu |
| Drag files from Finder into the Sources table | File › Import Sources… (⇧⌘I). Dropped files go through the **same** Import Review sheet; a drop never imports directly |
| Drag a split divider | Default sizes are usable; View › Show/Hide Sidebar and Inspector |
| Scrub/adjust epoch or channel by dragging | Numeric field + stepper (↑/↓ keys); Set Epoch…/Set Channel… sheets |
| Click a status icon | The status cell value is in VoiceOver. The inspector shows all dimensions; Source menu items perform the remedies |

All drags are undoable with the same names as their menu equivalents [A7].

## 6. Context menus

| Element | Items (groups separated by "—") |
| --- | --- |
| Library entry (show) | Open Show · Open in New Window — Add to Collection ▸ · Show in Finder — Remove from Library… |
| Library entry (unavailable) | the entry's remedies (Locate…, Grant Access…, Try Again) — Remove from Library… |
| Collection (sidebar) | Rename · New Collection… — Delete Collection… |
| Episode (sidebar) | Rename · Episode Info · Duplicate Episode — Add to Collection ▸ · Move Up · Move Down — Delete Episode… |
| Recorder group row | Rename · Start New Epoch — New Recorder Group… |
| Source row | Assign to Recorder Group ▸ · Assign Speaker ▸ · Use as Primary/Use as Backup — Download/Pause/Cancel/Retry (applicable ones) · Relink Source…/Grant Access… — Show Source in Finder · Remove from Episode… |
| Speaker row | Rename · Set Primary ▸ — Delete Speaker… |

Confirmation wording for removals (these are uncommon destructive actions [A13], so each one confirms):
- Delete Episode: "Delete “<Episode>”? Its setup is removed from this show. Source files aren't deleted." **Delete** / **Cancel**. Undoable.
- Remove Source: "Remove “<file>” from this episode? The file itself isn't changed or deleted." **Remove** / **Cancel**. Undoable.
- Delete Speaker: "Delete speaker “<name>”? Its sources become Unassigned." **Delete** / **Cancel**. Undoable.
- Delete Collection: "Delete the collection “<name>”? The shows and episodes in it aren't deleted." **Delete** / **Cancel**. Undoable.

## 7. Settings window and text size

The Settings window has a non-customisable toolbar with two panes. Its title matches the pane. Minimize and zoom are dimmed, and it reopens on the last pane [A12]. Changes apply immediately and are not undoable.

| Pane (symbol) | Control | Default | Caption (exact) |
| --- | --- | --- | --- |
| **General** (`gearshape`) | Toggle **Save changes automatically** | **On** | On: "WaveWrangler saves your changes as you work. You can also choose File › Save at any time." Off: "Changes are saved only when you choose File › Save (⌘S). WaveWrangler will ask before closing a show with unsaved changes." |
| General | Pop-up **Text size**: 100% · 125% · 150% · 175% · 200% | **100%** | "Makes text in WaveWrangler windows larger. Also in View › Text Size." |
| **Sources** (`music.mic`) | Toggle **Download sources automatically** | **On** | See [states §6](states-and-recovery.md#6-source-download-setting-on-and-off) for the On and Off captions |

VoiceOver: the toggles are switches. Each label is the toggle text, the value is "on"/"off", and the caption is the accessibility help.

**Text size (CMD-20).** macOS doesn't support Dynamic Type [A16], but Apple asks apps to offer enlargement to at least 200% [A1]. WaveWrangler therefore provides its own scale. It applies to every WaveWrangler-drawn text and to symbols that carry meaning [A16]: sidebars, tables (row heights grow), inspector, sheets, message bars, popovers, blocked panels and the Settings window. The menu bar, native open/save panels and system alerts follow system settings. At 200%:
- Essential text (names, states, units, numeric values, button titles) is never clipped. It wraps, or uses middle truncation with the full text in the help tag, the VoiceOver label and the inspector [A17].
- The inspector may become a scrolling column. The sidebar and inspector may auto-collapse in narrow windows, but they stay reachable through View commands.
- Controls stay at least 20×20 pt (default 28×28 pt) [A1].
- Whether a separate macOS system per-app text-size setting exists on macOS 26 is **(unverified)**. If Mac finds one, honour it in addition to this setting.

## 8. Keyboard-only flows for core tasks

These are the canonical key sequences. [Accessibility acceptance](accessibility-acceptance.md) uses them by ID and adds the expected AX roles, values and focus. "Menu ›" means choosing the item through the menu bar with the keyboard (⌃F2, or Help-menu search with ⌘?).

| ID | Task | Keyboard-only path |
| --- | --- | --- |
| K01 | Create a show | ⌘N → type name → Tab to location (panel) → Return → the show window opens with focus in the episode list showing the empty state → Tab to **New Episode** |
| K02 | Add an episode | ⇧⌘N → inline rename active → type title → Return |
| K03 | Edit episode metadata | ⌘I → Title field focused → edit → Tab to Number, Season, Recording date, Notes → each commit on Tab/Return creates a named undo |
| K04 | Edit show metadata | Arrow to Show Info in the sidebar → Tab to inspector fields → edit |
| K05 | Organise collections | ⇧⌘L → Menu › File › Library › New Collection… → type name → Return → Tab to entry list → select show → Menu › File › Library › Add to Collection › *name* |
| K06 | Reorder | Select a row → ⌥⌘↑ / ⌥⌘↓ |
| K07 | Import a messy folder | ⇧⌘I → choose folder in the panel (⌘⇧G path entry or arrow navigation) → Return → Import Review: arrows through rows, Space toggles Include, Tab to the pop-ups, ⌥↓ or Space opens a pop-up → **Accept All Suggestions** or edit rows → Return = **Import N** |
| K08 | Confirm/correct grouping | Select sources (⇧↓) → Menu › Source › Assign to Recorder Group › *group* (or Return → inspector "Recorder group" pop-up) |
| K09 | Set epoch/channel | Select a source → Menu › Source › Set Epoch… → type the number → Return; or Return → Tab to the Epoch field → type or ↑/↓ |
| K10 | Assign speaker; choose primary/backup | Select source → Menu › Source › Assign Speaker › *name* → Menu › Source › Use as Primary (or inspector Role radio: Tab, then arrows) |
| K11 | Relink a missing source | Select the "Not found" source → Menu › Source › Relink Source… → choose a file → Relink sheet: read the comparison table (Tab into it, arrows by row) → Return (match) or check "I've checked…" with Space → Tab to **Use This File Anyway** → Space |
| K12 | Regrant access | Select a "Needs permission" source → Menu › Source › Grant Access… → Return on the pre-selected file → confirm as K11 |
| K13 | Toggle autosave | ⌘, → General pane → Tab to **Save changes automatically** → Space |
| K14 | Toggle source downloads | ⌘, → ⌃F5 (settings toolbar) → → to **Sources** → Space → Tab to the toggle → Space |
| K15 | Explicit save | ⌘S; check with Menu › View › Show Save Status |
| K16 | Resolve a conflict | Menu › View › Show Save Status → **Resolve…** → Return default **Save Mine as a Copy…** (or Tab to other choices) |
| K17 | Recover prior work | Menu › File › Revert To › Browse Saved Versions… → arrows → Return → confirm **Revert** |
| K18 | Cancel/retry a download | Select source → Menu › Source › Cancel Download → confirm (Tab to **Cancel Download**, Space) → later Menu › Source › Retry Download |
| K19 | Unknown-newer refusal | ⌘O → open the file → message bar is read; Tab reaches **Close Show**; edit commands and Save, Duplicate and Save As are dimmed |
| K20 | Close with unsaved changes | ⌘W → sheet: Return = Save, Esc = Cancel, ⌘⌫ = Don't Save (standard) |
| K21 | Open recent / reopen | Menu › File › Open Recent › *show*; or ⇧⌘L → arrows → Return |
| K22 | Second window on a show | Menu › File › New Window for “*Show*” → ⌘` cycles windows |
| K23 | Change text size | ⌘+ repeatedly up to 200%; ⌘0 resets |
| K24 | Navigate destinations | ⌘1–⌘4; on a blocked panel, Tab to **Go to Setup** → Space |
| K25 | Resolve unavailable show (library) | ⇧⌘L → arrows to Unavailable → Tab to the entry list → arrows → Tab to the detail remedy (Locate…/Grant Access…/Try Again) → Space |
