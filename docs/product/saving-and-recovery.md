# Saving and recovery

Your show stores editing decisions. Original recordings stay referenced in
place, so saving the show is not a backup or consolidation of all its media.

## Know what is saved

Use the toolbar's save-status item or **View > Show Save Status** for details.
**Saved** means the current local show was verified on disk as a complete version.
If its folder syncs, the cloud provider uploads it separately.

**Edited**, **Saving**, **Not confirmed**, and **Not saved** do not mean the same
thing. In particular, **Not confirmed** means a write could not be verified and
the open edits still count as unsaved.

**Settings > General > Save changes automatically** controls autosave.
**File > Save** works explicitly in either mode. With autosave off, save before
closing or respond to the unsaved-changes prompt.

Windows for the same show share Save state and Undo history. **Undo/Redo**
restores editing decisions such as timing, cuts, mutes, clips, and mixer settings;
it never rewrites original recording bytes. Capturing Audio Unit state can take
time or require resolving an effect-editor error before a save can finish.

Ordinary saves write a captured version in the background so you can keep
editing. Changes made during a save remain unsaved until a later save verifies
them; **Saved** never describes an older version while newer edits are pending.
Saving a copy that becomes a separate show can briefly block interaction while
its identity and Undo history change safely. Closing also waits for pending
recovery work so **Don't Save** finishes discarding unsaved checkpoints.

## When a save fails

Keep the document open and inspect the status action.

| Status | What to do |
| --- | --- |
| Not confirmed | Use **Check Again** or **Save a Copy**; do not assume the write is complete. |
| Can't reach | Make the location available, then **Try Again**, or **Save a Copy Elsewhere**. |
| Not saved / full disk / permission failure | Resolve the stated problem and retry, or save elsewhere. |
| Conflict | Use **Resolve** and inspect versions; another writer's changes are not silently overwritten. |
| Read-only | Read the reason before attempting a copy or format update. |

Read-only recovery and newer-format cases have different restrictions.
Do not treat **Duplicate** or **Save As** as a way to down-save a newer show.
Cloud-provider conflict versions are reported, not automatically merged or
removed.

## Recover unsaved work

On opening a show, WaveWrangler may offer **Restore Unsaved Changes** from a
local edit checkpoint. Restored changes are still unsaved: inspect them and
save deliberately. The offer does not mean the saved show was already replaced.

Changes based on an older revision, or a second set of recoverable edits, may
only be opened with **Open as Separate Copy** so neither version is overwritten.
Unreadable or newer-format checkpoints remain kept and are reported rather
than applied. **Discard** is a separate confirmed decision.

If an incomplete save was recovered, read the persistent message and inspect
the version that opened. Recovery is not a substitute for independent backups.

## Older and newer show formats

An older show may require **Update** before saving. The update requires explicit
consent and backs up the original bytes. **Open Read-Only** lets you inspect
without committing the format change. A failed update keeps the original
unchanged and offers recovery actions.

Keep a separate backup before moving important work between app versions.
Newer or damaged formats may open read-only instead of being silently rewritten.

## Keep source access separate from document saving

Imported recording authorization and file access belong to this Mac.
A synced show does not automatically grant another Mac access to its audio.
Keep originals available and use **Grant Access**, **Relink Source**, or the
recording's displayed remedy when needed.

Changed identity can invalidate alignment, transcripts, and edits. Restore the
intended original or review the replacement; do not clear warnings by pretending
two different recordings are identical.

For development builds, quit the editing app before replacing its bundle.
If permissions stop resolving after a rebuild, launch the freshly built app
before retrying access. Keep its DerivedData separate from test builds as shown
in the [local quick start](../../README.md#build-and-open-locally).

[User guide](README.md)
