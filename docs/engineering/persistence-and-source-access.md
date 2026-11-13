# Persistence and source access

The portable show records user work, not permission to read recordings.
Device-local grants and observations are separate; derived assets are
rebuildable. Originals remain immutable throughout import, editing and export.

## Canonical formats and migration

The current show schema is **14**, library schema **2**
(`WWCore/ShowDocumentModel.swift`). Show additions include the mixer (9),
supplemental audio (10), production bounds (11), rack positions (12),
speaker mutes (13), and publication metadata/artwork (14).
Embedded time-map format changes require a show schema bump too.

Canonical envelopes contain `checksum`, `format`, `payload`, `publicationID`,
`revision` and `schemaVersion`. SHA-256 covers canonical sorted payload bytes;
it detects integrity failure, not authenticity. A revision orders publications
but does not prove identity: conflict detection compares the exact opened base,
publication ID and checksum.

Unknown-newer envelope and embedded schemas are refused before version-specific
payload/checksum interpretation. Do not treat them as damaged files, downsave
them, or rewrite recovery/derived state on refusal.

Supported schemas 1-13 migrate directly to current only with explicit consent.
Retain an exact-byte, nonoverwriting backup and publish through the ordinary
verified protocol. Never invent speaker roles, cuts, metadata or permissions.
In particular, schema-1's ambiguous channel zero becomes unknown unless the
old bytes explicitly establish that channel. Test migrations against independent
old-format expectations, not only the current encoder.

## Verified publication and recovery

Publication validates the candidate and retained prior, coordinates against the
exact base, stages/flushes/verifies bytes, replaces the destination, then
independently reads it back. Library acknowledgment and rebuildable indexes
follow successful document publication. A postreplacement failure or uncertain
acknowledgment is not a verified Saved state.

Recovery is device-local and keyed by logical ID: validated prior publications
(last three), unpublished edit checkpoints, conflicts and migration backups
have distinct roles. They are not cross-device backup guarantees. A damaged
document may offer a complete validated untitled recovery copy; do not merge
fragments, silently overwrite the original, or discard unknown-newer bytes.
An edit checkpoint cannot claim the document's URL was saved.

A Duplicate gets a new `ShowID`. A Finder copy keeps the ID and must expose the
collision rather than silently merging histories or grants. Library location
changes use the pending journal and copy/verify/switch protocol, not a path
preference change before the new copy is known durable.

## Shared document, Undo and native state

`ShowDocumentStore.apply(_:coalescing:_:)` is the canonical edit boundary.
Apply a validated transformation to the live value, with a named Undo action;
do not replace unrelated later edits with a captured old model.
All windows for a show share the store, dirty/save state and Undo manager.
Episode-bound windows do not retarget on deletion or failed restoration.

Native Audio Units are not ordinary value properties. Before Save/autosave,
Undo/Redo, close or incompatible replacement, capture authoritative full state
from the current loaded chain. A stale/failed capture aborts visibly, rather
than saving defaults or dropping edits. Undo/close suspend and drain native
observers and dismiss stale parameter editors. State observers may cache a
candidate, but a document barrier always obtains a fresh capture.

Capture before entering AppKit's autosave file-access context. Nested saves
reuse that capture; idle pre-captured saves start synchronously. Native capture
and overlapping publication defer correctly, busy implicit autosaves reschedule
instead of accumulating a backlog, and the save queue must not retain a mixer
edit transaction while awaiting publication. Later edits remain dirty even when
an older captured candidate verifies.

### Responsive saving

Balance user experience, actual and perceived performance, and write safety.
Routine saving must not interrupt repeated cuts or other edits; even a
one-second UI stall impedes editing. Prefer non-UI-bound work, not a longer
autosave delay or a premature Saved indicator. Narrowly scoped blocking remains
appropriate when needed to preserve native state, safely replace document
identity or finish recovery cleanup before closing.

After native capture, `ShowDocument` takes an immutable value snapshot and
enters `super.save` synchronously. AppKit's writing callback explicitly calls
`unblockUserInteraction()` **before** encoding or waiting for the app-wide
persistence lane. Merely enabling asynchronous writing does not release the
UI. Worker code uses captured inputs and synchronized candidate/receipt storage,
never live main-actor model or status. Keep stock `super.writeSafely`,
`AlreadyCoordinated`, exact-base conflict checks and independent read-back.
AppKit's change-count token preserves edits made during publication; a verified
older snapshot must not clear those edits or acknowledge their title as saved.

Presentation uses the captured location and conservatively unsaved model state
during writing, rather than AppKit file-relative getters that may wait for file
access. Those display values are not source-binding or publication authority.
Save a Copy Elsewhere remains synchronous while adopting a new logical show
identity and replacing Undo history, so late edits cannot be overwritten.

One shared lane serializes publication, background checkpoint encoding/writing
and automatic recovery cleanup. Checkpoints allow at most one in-flight snapshot
per document; late status updates check model generation, base and close state.
Close drains queued recovery work before returning. Don't Save then finishes
discarding checkpoints, preventing a late write or immediate termination from
resurrecting discarded recovery; a cleanup failure visibly refuses close.
Explicit recovery review and uncertain-save reconciliation retain their safety
checks.

Do not open an Undo group across an await. Async work needs exact generations
and identity/slot currency, including equal-byte Undo/restore ABA. Auxiliary
mixer/review windows reuse the same native owner and document history.

## Metadata, permission and content

Source state distinguishes unknown, missing, changed, denied, unverified,
residency, transfer and physical identity. A path, filename, bookmark, sample
geometry or saved witness is never sufficient authorization.

Metadata-only review performs no content/header/hash/decode/preview work and
does not download a dataless file. Explicit Import Review confirms identities
and captures the raw witness before permission publication. Open, restore,
background validation and derived-cache hits must not upgrade permission.
Availability OFF must remain a zero-content-work path.

`WWSources.SourceIO` owns metadata/bookmarks/scopes and an explicit provider
request seam. Every sample/header read goes through `WWDecode.SourceDecoder`.
Only package-access `WWDecode/SystemSourceContentIO.swift` opens original
content: `O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK`, verified with
`fcntl(F_GETFL)`. AudioFile callbacks use witnessed `pread`, with no write or
set-size callbacks. Reject dataless content and disable materialization around
open and each content read; do not use a check-then-decode alternate API.

The gateway keeps complete current raw witnesses, measured format and access/
source mutation generations. Revalidate them on reads and cache hits.
Persistent cleanup identity can reuse a confirmed recorded witness where every
persistent identity field matches even after a remount changes device/fsid;
this narrow continuity rule never weakens the live gateway's exact witness.

Never write, rename, move, replace or delete an original. Never substitute a
same-name file or infer an unknown channel. Device access records are keyed by
`(ShowID, SourceID)` and are not portable document content.

`ForbiddenAPITests` recursively scans package modules and app code for alternate
content readers. Memory-only PCM conversion in `WWDecode/PCMResampling.swift`
and `WWSpeech/LocalWhisper.swift` is not an alternate file-opening entitlement.
Preserve the scan when adding a module.

## Import and derived lifecycle

Recording algorithms use `Episode.alignmentSources`; `Episode.sources` also
contains supplemental assets. Assets cannot silently acquire recorder groups,
Primary/Backup assignments, ASR or recording-input-gain roles.

Supplemental imports first qualify all candidates, then make one canonical
transaction. Pending authority is opaque and engine-bound; canonical publication
precedes conditional atomic adoption of owned access records. Failure after
publication leaves blocked, repairable references and a visible error, not a
claimed rollback or successful import. Physical matches with recording-purpose
sources block asset reuse. See [program timeline](program-timeline.md).

Derived cache roots must not be in/contain source folders or cloud-backed
locations. Keys include every applicable source identity, format interpretation,
map content/revision and recipe dependency. Publish only after a same-turn
currency check. Shut down and join `DerivedJobCoordinator`/pipeline work before
releasing source access; late results must not resurrect access or state.
Cache corruption may trigger a visible rebuild, never source substitution.

Changing the interpretation of identical source bytes requires
`formatInterpretationVersion` and dependent recipe/key updates.
Maintained decoder pins do not inherit historical freeze qualification;
see [test support](../../test-support/README.md).

## Public metadata and artwork

Show defaults and episode per-field overrides are canonical. `nil` inherits,
empty text omits, and `false` is an explicit Boolean override.
`PublicationArtworkSelection.none` means omit, unlike `Optional.none`.
Public descriptions never come from private Notes or file paths.

Portable artwork retains original verified JPEG/PNG bytes, schema 1, at most
10 MiB and dimensions 1-4096 pixels, one complete image. The native artwork
picker is a separate grant; audio authorization does not cover it and no
network fetch is implied. Export has a smaller artwork limit and per-format
omission consent; see [export codecs](export-codecs.md).
