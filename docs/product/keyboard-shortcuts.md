# Keyboard shortcuts

Shortcuts apply to the active window and selection. Unavailable commands are
dimmed. This guide spells out modifier names: Command, Shift, Option, and Control.

## Shows, episodes, and files

| Action | Shortcut |
| --- | --- |
| New Show | Command-N |
| New Episode | Shift-Command-N |
| Open | Command-O |
| Library | Shift-Command-L |
| Import Sources | Shift-Command-I |
| Episode Info | Command-I |
| Save | Command-S |
| Duplicate | Shift-Command-S |
| Save As | Option-Shift-Command-S |
| Close window | Command-W |
| Close Show | Shift-Command-W |
| Settings | Command-comma |

## Workspace and editing

| Action | Shortcut |
| --- | --- |
| Setup / Recordings & Speakers | Command-1 |
| Alignment | Command-2 |
| Edit & Cleanup | Command-3 |
| Export | Command-4 |
| Toggle sidebar | Control-Command-S |
| Toggle inspector | Control-Command-I |
| Undo | Command-Z |
| Redo | Shift-Command-Z |
| Move selected list item up/down | Option-Command-Up / Down |
| Bigger / smaller text | Command-plus / Command-minus |
| Actual text size | Command-0 |
| Full screen | Control-Command-F |

## Timeline and audition

With the timeline workspace active and no text field, button, table, boundary
handle, or other control owning the key:

| Action | Shortcut |
| --- | --- |
| Play / Pause | Space |
| Jump backward / forward | Left / Right |
| Audition Selection | Command-Return |
| Stop Audition | Escape |

Set the jump interval in **Settings > General > Timeline keyboard controls**:
1, 2, 5, 10, 15, or 30 seconds; the default is 5. Held Space does not repeatedly
toggle playback. Focused controls retain their own keyboard behavior.

For filler boundary handles, Left/Right adjusts by 1 ms. For focused Audio Clip
automation points, Left/Right nudges time by one 48 kHz output frame; focused
level handles use Up/Down amplitude steps of `0.01`. Escape cancels an active
automation gesture.

In recording Import Review, Space toggles **Include** for selected rows,
Delete excludes them, and Return imports when available.

[User guide](README.md)
