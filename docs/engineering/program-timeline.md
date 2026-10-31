# Pure program-time composition (F2)

`WWCommonEdit` owns `ProgramTimeline`, `ProgramComposition`, and
`AudioEnvelopeEvaluator`. They are immutable, Sendable value snapshots, not
playback, an editor, source access, persistence services, or recorder-clock edits.
F1's schema-10 arrangement and shared model transaction/Undo path remain in use.

## Coordinates and boundaries

The chain is **original-aligned dialogue -> merged `ManualCutTimeline` ->
explicit inserted time -> final program**. All these coordinates are signed
integer 48 kHz frames. Native asset trims remain half-open native frames.
Endpoints use the existing signed day envelope, not a new zero-based timeline.
An extent is a hull, not a guarantee of samples throughout its interior.

Construct `ProgramTimeline(episode:dialogueFrames:)` with the complete original
aligned coverage from the caller's current accepted-map context. Coverage is
required if there is accepted alignment and forbidden without it. It is not
per-source coverage, approval, or a live-currency check: existing accepted-map
adapters must still classify speaker gaps/unsupported/discontinuous source
regions and retain localized adaptive corrections. This kernel neither decodes
the embedded map nor bypasses those adapters. In audio-only episodes omit coverage;
no fictitious accepted map is created.

| API | Contract |
| --- | --- |
| `dialoguePosition(atAlignedFrame:)` | Sample mapping: `.mapped`, `.removed(interval:seam:)`, or `.outsideCoverage`. A seam returned for removed audio is not a speaker sample. |
| `inverse(atProgramFrame:)` | `.dialogue(frame:)`, `.insertion(region:offsetFrames:)`, or `.outsideCoverage`. Insertion interiors never invent dialogue. |
| `project(_:)` | Placement points on the current accepted grid, including before/after finite coverage: `.placed`, `.clampedToCutSeam`, or `.reviewRequired`. The grid binding is not sample coverage. |
| `segments(in:)` | Exact contiguous request partition into kept dialogue spans, insertion-only intervals, and explicit outside-dialogue intervals. |
| `composition()` | Atomic complete clip projection and bounds; stale/invalid clips refuse the result, never disappear from a successful extent. Valid bound points outside dialogue coverage are included. |

Placement and sample domains are deliberately separate. With a current accepted
binding, valid placement points may lie anywhere on its original-aligned grid
within the signed day limits, even beyond the finite map/audio coverage.
`dialoguePosition`, `inverse`, and `segments` retain their finite **sample**
coverage and never extrapolate an accepted clock map or authorize a source read.
The older placement `.outsideDialogueCoverage` outcome and related errors remain
for caller compatibility, but finite audio coverage alone no longer emits them.

Cuts merge overlap and adjacency once. Every reconstruction uses the original
saved anchors: moving, resizing, or restoring cuts never accumulates per-clip
subtraction. A start inside `[cutStart, cutEnd)` moves to its seam and retains all
clip audio. The exclusive cut end belongs to retained later dialogue. For a
20-30 second cut, an unpinned start at 35 becomes 25; a 25-second clip starting
at 15 remains the intact 15-40 interval; an absolute start at 35 stays 35.

Production always collapses **all** active cuts. There is deliberately no
`revealing:` argument. Keep Show cut's existing review prescription separate;
showing/hiding must not reproject saved anchors, change pins, or ripple twice.

## Insertions and placement edits

- Dialogue region anchors use the merged cut map, including placement boundaries
  before/after finite dialogue coverage. Program-origin regions use a
  cut-independent **pre-insertion** origin grid, including audio-only programs.
- Resolve regions by base boundary, then saved `insertionRegions` array order.
  Distinct original anchors collapsed onto the same cut seam also use array order.
  Ordinary unpinned placements at that boundary follow **every** insertion there.
- Regions are positive half-open intervals with stable IDs. No nesting is
  supported. An `.absolute` **region** anchor throws
  `unsupportedAbsoluteInsertion`; F7 must not offer pinned regions. An `.absolute`
  **clip** anchor is supported final program time and never follows cuts/insertions.
- Region-relative clip starts are inside their named region. Full clip duration
  may overhang its region; placement does not split, stretch, or shorten a clip.
  Earlier edits move that region and its relative placements together.
- Program-origin clips follow insertions, never dialogue cuts. Later alignment
  admission does not silently reinterpret them. Explicit
  `reconciledAnchor(for:)` preserves the currently resolved position.

F5 should use `unpinnedAnchor(atProgramFrame:)` against the **current** projection
for placement after existing edits. Insertion interiors return a region-relative
anchor. With accepted timing, all other positions return a current map-bound
original-aligned **placement point**, including before/after finite coverage:
first remove the current insertion offsets, then invert the current merged cuts.
Only without an accepted binding does it return a pre-insertion program origin.
This prevents applying earlier cuts/insertions twice and lets later dialogue
cuts ripple unpinned outros. The mapped original point is bounds-checked; an
inverse outside the signed day grid refuses instead of falling back to an origin.
`pinnedAnchor(for:)` and `unpinnedAnchor(for:)` preserve resolved position;
review-required anchors refuse these helpers. Submit the returned anchor through
F1's `replacingAudioClip`/compound operation and normal shared-store Undo.

For dialogue `[0s,10s)`, a new unpinned clip at 12s binds to original grid point
12s. Cutting `[2s,4s)` moves it to 10s; an absolute 12s pin remains 12s. Both the
original 12s point and final 10s position still have no dialogue sample. If a
clip is instead placed/unpinned at final 12s **after** that cut, its inverse
anchor is original 14s, so it remains at 12s until another edit; restoring the
cut moves it to 14s. Existing program-origin clips are never silently rebound:
explicit `reconciledAnchor(for:)` inverse-anchors their current resolved position,
including outside finite coverage, without moving them at reconciliation.

Bindings use F1's SHA-256 over the **entire canonical `TimeMapVersion`**, not a
revision number or pipeline/cache object identity. A same-revision byte change
requires review. Stale regions refuse construction because they affect the
entire projection; stale clips have individual review outcomes and refuse
complete composition.

## Source scheduling and extents (F4/F5/F8)

`ProgramAudioClip` retains the exact original clip, asset geometry, and separate
`programFrames`. Ordinary duration is F1's checked
`CEIL((nativeEnd-nativeStart) * 48000 / nativeRate)`; a checked `outputWindow`
selects a subrange of that nominal grid without changing native support. Clips sharing a source retain
distinct clip IDs, trims, channel orders, envelopes, and placements.
`sourceChannels` expands nil to native channel order without changing saved state.
`sourcePosition(atProgramFrame:)` returns exact native position
`nativeTrimStart + (outputWindow.offsetFrames + localProgramFrame) * nativeRate / 48000`,
or outside coverage (an absent output window has offset zero).
The exclusive program endpoint is not scheduled; the final CEIL-owned sample's
native position is still strictly inside the trim.

`ProgramComposition.programFrames` includes all dialogue spans, all regions, and
all clips, independent of visibility, mute, Solo, and live faders. Nil means truly
empty. Overflow, bounds violations, invalid shapes, unsupported anchors, and
review requirements are typed refusals. No live controls are inputs to projection.

F4's `MixerRecipe` freezes normal `EpisodeProcessingInputs`, current accepted timing
through the full processing inputs and `ProgramComposition`, live source witnesses,
decoder interpretation, supplemental access-generation evidence, track routes, program
range and seek/latency/tail policy. Program placement
does not reset/reanalyze recordings or invalidate original transcript/word/source
waveform partitions. Nonempty arrangement recipes require the complete composition;
the legacy speaker-only initializer cannot silently omit clips or insertions.

## Exact envelopes and the additive schema-10 shape

Ordinary integer `frame`/`amplitude` point bytes and initializer behavior are
unchanged. Optional `point.fraction` stores a canonical proper fraction using
`AudioEnvelopeCoordinate`. Optional `envelope.window` explicitly retains a curve
coordinate origin; its `offset` uses the same helper and is omitted when zero.
`window: {}` is meaningful retained-support mode, not the ordinary absent window.
No new schema version, module, decoder, or history store is introduced.

The current local window is `[offset, offset + duration]` on the retained curve.
Ordinary envelopes require every point in `[0, duration]`; windowed envelopes
permit at most the nearest supporting knot before and after the current window.
Points remain strictly ordered by their **whole plus fraction**, with finite
amplitude 0...1. Origin offsets are nonnegative and at most one day. A retained
origin plus one local day requires a two-day **internal curve-coordinate** bound;
program, native-asset, and local-duration limits are unchanged. Canonical
denominators are at most 192,000, covering supported native trim phases. Invalid,
noncanonical, or externally combined unrepresentable fractions refuse visibly.

`AudioEnvelopeEvaluator` evaluates linear **amplitude**, holds endpoints, returns
unity for empty curves, and preserves exact silence. Integer or rational local
queries check the current window. All coordinates/interpolation ratios are exact
until the final Double gain calculation. Seeking/chunk history cannot affect it.

Use `sliced(to:)`, `split(atLocalFrame:)`, `trimmedEnvelope(of:asset:to:)`, and
`splitEnvelope(of:asset:atNativeFrame:)`. They retain exact bracketing knots and
their original amplitudes rather than repeatedly materializing rounded boundary
gains. `settingPoint(atLocalFrame:amplitude:)` adds/replaces a fade at the current
playhead or exclusive endpoint, even after an off-grid native trim. Do not write
that local frame directly into retained curve coordinates.

Example: trimming native frame 1 from a 44.1 kHz clip advances the curve by
`160/147` program frames. A new point at local frame 10 has curve coordinate
`11 + 13/147`. Successive native trims add exact phases; local slices add integer
offsets. Further trim/split/Codable reopen preserves the same continuous
piecewise-linear curve and identical evaluated gains at matching sample instants,
not approximations accumulated from earlier sampled boundary values.

### Retained nominal output ownership (F4/F5)

This is **not** a claim of sample-for-sample concatenation of independently
CEIL-rounded native splits. A 44.1 kHz `[0,441)` trim owns 480 program frames.
Splitting at native frame 1 yields independently rounded durations 2 and 479,
total **481**, not 480. The leading sample positions are native `0, 147/160`;
the trailing first position is native `1`. Appending the trailing clip at
program frame 2 is not the unsplit native position `294/160`.

The original regression preserves that discrepancy explicitly: for a 0-to-1 ramp over
480 frames, the trailing first gain is `1/441`, not the original frame-2 gain
`1/240`. Ordinary integer trims still behave exactly that way.

The additive schema-10 `AudioClip.outputWindow: AudioClipOutputWindow?` resolves
sample-preserving edits. It stores `offsetFrames` and positive `countFrames` on the
**retained trim's nominal 48 kHz output grid**, bounded by its ordinary CEIL duration.
Absent means the old shape and bytes. Present means `trim` is retained processing
support, not the effective selected audio; `durationFrames(asset:)` is the owned count.
`nominalDurationFrames(asset:)` and `ownedOutputFrames(asset:)` distinguish support
from selection. No source frames are deleted or fabricated.

F5 uses `ProgramAudioClip.split(atProgramFrame:timeline:)` against the current
projection. Leading retains the clip ID; trailing receives a new ID and a
position-preserving inverse anchor, or absolute placement for a pinned clip.
Already-windowed clips split relative to their current window. Both halves retain
identical native support and SRC origin. Envelopes use the existing exact
`sliced(to:)` operation, not a resampled boundary gain or a source offset copied
into the envelope domain. Apply both clips in one whole-value arrangement edit/Undo.

Thus splitting the example at program frame 2 owns **2 + 478 = 480** frames.
Trailing begins at native `294/160` and curve gain `1/240`, exactly matching the
unsplit signal. Repeated splits, odd producer windows, seeks and 147 Codable
reopens retain sample-for-sample asymmetric stereo/impulse/envelope results.
`NominalPCMRenderer` uses absolute rational source phase and the existing sinc
prototype, with exact-copy 48 kHz identity routing. Only taps outside the original
retained trim use explicit zero; a cropped output window never resets/clamps taps.
This reuse does not extend historical DSP qualification.

For edge edits, `cropped(toLocalFrames:)` preserves phase and the local curve.
`AudioClip.selectingOutputFrames(_:asset:envelope:)` can crop or extend ownership
within that same retained support, with an explicitly supplied valid new curve.
It preserves placement; use the current timeline inverse helper separately if the
start moves. Discarded envelope knots cannot be invented by extending a crop.
The native-trim envelope helpers explicitly refuse an existing output window;
never clear it or round its first fractional source position to a native frame.

F7 continues to submit insertion regions/anchors through `ProgramTimeline`;
the production adapter partitions dialogue, insertion-only space and exterior
gaps before calling the existing accepted/adaptive recording readers.
`AlignmentRuntime.programComposition` provides complete bounds without requiring
fake accepted timing for audio-only episodes. `playProductionMix(interval:)` takes
program seconds; `productionPlayheadSeconds` retains the final program clock while
existing recording waveforms hold the following seam during insertion-only time.
F8 evaluates/adds fade points on the **current clip-local output grid** through
`AudioEnvelopeEvaluator`, including after splits/windows. No F5/F7/F8 editor,
Add Audio/drop controls, fade UI or delivery-file/export path is included in F4.

## F5 editor and staged-import integration

`AudioClipEditorModel` is the editor-local selection/gesture owner, using the
existing `ShowDocumentStore` and `EpisodeAlignmentModel` runtime. It does not own
another document history, decoder, mixer, or permission registry. Completed edits
use `AudioClipEditing.moving`, `pinning`, `resizing`, `duplicating`, and the existing
`ProgramAudioClip.split`. A preview never publishes canonical state. The model
checks the exact store generation before applying a completed gesture, so an
edit/Undo/restore to equal bytes cannot make a stale gesture current again.
Resize bounds are on retained nominal output support, not rounded native frames.
Unity curves may extend within that support; extending a cropped nonempty curve
refuses because discarded automation cannot be reconstructed. F8 can supply an
explicit valid curve through `selectingOutputFrames` instead.

Reusable staging surfaces for F6:

| Surface | Ownership and contract |
| --- | --- |
| `StagedAudioImportCoordinator.scan(_:in:programSeconds:)` | Metadata-only selection review bound to the exact originating editor, window, show, episode, and store generation. The caller captures the default program time at action start. |
| `commit(_ review: AudioImportReview)` | Explicit content authorization; sequentially prepares **every** selected candidate and publishes the resulting source/asset/track/clip batch in one `settingAudioState`/`store.apply("Add Audio")`. No Undo group spans an await. |
| `WWSourcesSetupEngine.preparePendingImport(candidate:fromScan:)` | An opaque engine/scan/candidate-bound pending token. Uses existing importer bookmarks, duplicate checks, `RelinkEvaluator.applyConfirmed`, and the witnessed gateway. No device record is published yet. |
| `validatePendingImport(_:)` | Rechecks the live token, engine lifetime, scan, local original, bookmark, complete witness, and duplicate/occupied identity. Returned read evidence has no independent authority. |
| `discardPendingImport(_:)`, `discardScan(_:)`, `shutdown()` | Revoke only owned unpublished pending authority. Decoder/preparation cancellation cleans its own unpublished work. |
| `AlignmentRuntime.qualifyAudioImport(_:progress:)` | Normal WWDecode qualification and the runtime's existing F3 `nativeSources` actor/root. Produces verified geometry plus bounded source-domain waveform bins. Original media remains immutable. |
| `adoptPendingImports(_:validatingPublication:)` | Consumes the full token batch once, checks the exact canonical publication/source ownership around awaits, and conditionally adopts device-local access. Failure never rolls back the canonical edit. |

`DeviceAccessImportStore` is an additive capability of the existing in-memory and
file access-store actors, not a second persistent ledger. `insertNew` validates
the whole batch and refuses every occupied key (even equal bytes) and duplicate
key before publication. It returns snapshots containing the store instance
identity and opaque exact mutation generation. `discardImported` removes only
still-owned snapshots under the same serialized boundary, returns ownership
refusals, and preserves subsequently changed/regranted records, including ABA.
The file implementation uses its existing synchronous load/persist boundary;
this is not a new cross-process compare-and-swap claim. Arbitrary access stores
without this capability refuse staged adoption rather than looping over `save`.
After canonical publication, failure/cancellation leaves blocked, repairable
references and an explicit relink/Undo explanation.

`AudioTimelineProjection` is a distinct immutable **presentation** value. It
retains only dialogue/cut/insertion geometry, not clip arrays, names, selection,
or playhead state. `EpisodeAlignmentModel.presentationTimeline` is shared with
docked/detached cleanup review, transcript indexes, marker geometry, source
waveforms, locator presentation, and diagnostic listening partitions. A temporary
Show cut projection restores only the portions not removed by other cuts;
production continues to use the original collapsed `ProgramTimeline`. Program
positions in real insertion regions have no recorder inverse; review-only
removed dialogue has no production inverse. Anchor/recorder/cut actions refuse
those unavailable inverses instead of inventing source samples.

`AudioClipTrackView` renders independent Audio Track rows alongside the existing four
comparison-layout branches. Source-domain measurements are indexed and reprojected
for placement/crop/split; viewport-sized equatable Canvas drawings keep clip/envelope
overlays separate from playhead ticks and row height. Blocking import/cold preparation
uses shared `TrackProcessingOperation`/`TrackProcessingPresentation`; warm waveform
detail retains the verified overview and stays interactive. Recording-only loading,
refusal, and no-audio placeholders require real recording sources and do not hide
supplemental lanes. Projection/waveform jobs use unique publication IDs even when
inputs repeat after cancellation; imported measurements transfer only once, and an
explicit refresh revalidates canonical access. A warm waveform hit still passes
native preparation's current evidence/format/witness policy before reuse.
F6 extends the staging coordinator with the audio-specific boundary below. F7
continues to use the current inverse-anchor helpers and shared presentation geometry;
F8 continues to use exact clip-local evaluator coordinates. Neither insertion nor
fade-point UI is part of this slice.

## F6 location drops and verified supplemental reuse

The macOS 26 drop adapter binds the target's whole `DropSession.itemsCount`, `id`,
and phase through a live `activeDropSession` binding. Pending and target-bound
snapshots support metadata-first and legacy-entry-first callback order without a
filtered-count or maximum-count fallback. A filtered `public.item` roster is never
count authority. A drop consumes a positive current
active inventory once. Exit/disappearance clear usable snapshots; ended or
consumed IDs cannot replay, and a session-ID mismatch requires a fresh entry.
Only exact file-URL providers are requested. Their count must equal the unfiltered
whole-session count, so mixed/recording payloads cannot become an admitted partial
file batch. These are metadata checks, not source grants or content reads. The
metadata helper tests cover both callback orders; real Finder callbacks still
require the corrected combined runtime gate.

`AudioTimelineFileDropTarget` registers location-only drops on the actual waveform
canvases, including clip blocks, recording canvases, the empty canvas, and unused
space below the tracks. Canvas-local geometry excludes headers/padding and follows
vertical scrolling without changing fitted row height. `AudioTimelineDropGeometry`
converts current display position through `AudioTimelineProjection` to a checked
whole 48 kHz program frame. Review-only cut interiors refuse. Header-only/ambiguous
drops have no target; nothing silently clamps to zero. Hover is a point and label,
not a provider load, header read, audio preview, or guessed duration.
Clip button labels and outer frames share the same computed block size so native
accessibility bounds describe the visible clip, not its entire lane. Finder UI
coverage uses those real bounds and refuses an occluded destination rather than
substituting another drop point.

The captured destination uses distinct `.defaultTrack`, `.existing(id)`, and
`.newTrack` intents; review resolves the default before confirmation. Audio lanes
retain their exact track. Recording/empty canvases review a generic new track.
`SetupFileDrop` remains the only location decoder; recorder-row, foreign/mixed,
web-URL and file-promise payloads refuse. The audio-only importer policy never
enumerates folders. Review reports skipped folders/symlinks/non-audio/hidden/
unreadable selections, including an empty non-importable review.

`AudioImportReview` retains explicit candidate order, selection, destination, whole
frame position (displayed as seconds), and layout. Drops default to sequential;
the picker still defaults to overlay. Ordering controls and an explicit Overlay
choice precede Import. Each selected file qualifies through the existing runtime.
Only then does its checked `AudioClip.durationFrames(asset:)` advance the sequential
cursor, with a separate current `unpinnedAnchor` for the next clip. The completed
sources/assets/tracks/clips publish in one `settingAudioState`/Add Audio operation.
No cut/insertion is applied twice; the batch never inserts time.

`WWSourcesSetupEngine.scanForAudioImport(_:in:currentModel:)` propagates ledger
read/schema failures and binds metadata review to a live, complete canonical model
validator. All physical matches use volume UUID plus persistent file ID, not the
importer's legacy first-match hint. The complete canonical roster must account for
the supplemental geometry/access data. Destination-episode supplemental assets
take preference over other episode matches. Any active recording or unknown-purpose
match blocks; an inactive device remnant is not an active source.

Every canonical active source needs recorded volume UUID and persistent file ID
to rule out physical aliases. Missing identity yields a named repair-required
refusal, never an invented empty match set. This is identity-inventory completeness,
not recording read permission or a requirement to bring every recorder online:
known nonmatching recording identities may be offline, provisional, or have no
readable bookmark/grant. Classification never opens their content and does not
require supplemental geometry for recordings.

`PendingAudioImport` is an opaque live engine/scan/candidate token with distinct
new, reuse-here, and copy-from-episode dispositions. New media delegates the existing
pending-new path. Reuse-here requires the saved confirmed bookmark, usable recorded
witness, exact store-issued access snapshot, and current qualified geometry. The
gateway re-admits both the saved original and dropped location. Persistent witness
continuity permits only mount device/fsid changes; every read still uses the entire
freshly admitted witness. Changed, provisional, missing, remote, dataless, stale,
or inconsistent originals require explicit existing repair.

Cross-episode copy uses that same engine-minted complete-cohort evidence but a new
episode-owned SourceID and read-only access record after explicit Import. It never
edits the origin's source/record/role/gains, recording timing, or unrelated episode
native editors. `RelinkEvaluator` and its `alreadyLinkedTo` protection are unchanged;
the audio-specific typed path accounts for the complete matching cohort instead of
erasing that hint or passing a filtered duplicate list. There is no allow-duplicates
switch, persistent media registry, or caller-created reuse permission.

Prepublication validation requires the original exact canonical snapshot/generation.
Postpublication validation permits only the single owned audio batch, checks exact
source/asset/clip ownership, and still checks the original physical cohort and access
generations around awaits. Reused-only batches skip new-record adoption altogether.
Mixed/new/copied batches share existing atomic `insertNew`/conditional
`discardImported`; later/regranted grants are preserved. Failure after publication
leaves blocked repairable references and an explicit relink/Undo explanation, never
a canonical rollback or a success-shaped fallback.

## F7 explicit insertion and safe inserted-time editing

`AudioInsertionEditing` is a focused app-side immutable operation over the
existing `Episode` and complete current `ProgramComposition`. Construction
revalidates their exact agreement. It changes only `audioArrangement` and
returns the whole validated arrangement/composition for preview. It does not
add schema, source access, decoding, DSP, clocks, history, or export machinery.

The fixed workspace chrome uses one compact, icon-only native **Inserted Time**
menu for explicit **Insert Intro...**, **Insert & Ripple...**, and region-edit
commands. Selected-clip inspector shortcuts remain separate. This does not add
a wrapping row that can consume the bottom-pane header at a 760-by-492-point
window with its 300-point inspector open. The real UI workflow asserts that
Detach Review remains contained and hittable at that same minimum, without
enlarging the window or hiding the inspector. Native static-text assertions read
the AX value first, then the label; preview numbers and semantic checks remain exact.

`inserting(at:duration:moving:id:)` accepts a final signed 48 kHz program point.
It inverse-anchors through the current `ProgramTimeline`. A region interior
refuses; an exact start edge reuses that verified region's non-insertion anchor
and inserts before its saved array entry. A final edge inverse-anchors after
the preceding regions. This preserves saved sibling order even when different
original dialogue points collapse to one cut seam. New region IDs remain stable
through preview and publication.

Intro defaults to the minimum retained dialogue-span, inserted-region, and
unpinned-clip start. Earlier unrelated pins are deliberately excluded when such
content exists; with only pinned/audio-only content it uses the complete first
program extent, or zero when empty. The sheet shows this signed default and
current original-aligned IN/OUT context. It never uses zero to silently leave
negative-time dialogue before an alleged intro.

Selected-clip retarget is explicit and initially unchecked. When chosen, an
unpinned clip becomes `.insertion(region: newID, offsetFrames: 0)`. An explicitly
chosen pin becomes `.absolute(frame: shownStart)` and remains pinned; every
other pin stays fixed. All clip fields except the chosen placement anchor
remain identical, including ID, track/source, native support, channel order,
`outputWindow`, and exact envelope. A 40-second bed at program zero and a
10-second region produce bed `[0,40)`, dialogue `[10,... )`, not a 40-second
gap or a cropped/split/stretched bed.

For a middle insertion at 20 seconds, a spanning `[5,45)` clip stays `[5,45)`;
an ordinary unpinned start at 30 becomes 40 for a 10-second insertion, and a
30-second pin remains 30. All recording lanes share this projection regardless
of visibility, mute, backup role, or localized dynamic-clock locks.

`replacing(_:at:duration:)` edits one region while retaining its ID. An unchanged
start preserves its existing base anchor and saved order. A moved destination
is explicitly measured in the program **with that region removed**. Valid
region-relative offsets follow the move without deletion clamping. Only
offsets at/beyond a shortened duration leave the region: they clamp to its new
tail seam and inverse-anchor in the resulting projection.

`removing(_:)` drops only the region. All starts attached to it clamp to its old
program start, after preceding same-boundary siblings and before later siblings.
The operation builds the resulting timeline without dangling clips, derives
valid current anchors at that seam, and restores every clip in saved order with
all audio retained. A surviving sibling beginning at the seam can legitimately
own an offset-zero anchor. Later ordinary starts/regions ripple through the
existing kernel, pins do not, and overhangs stay intact. The original source
samples and native duration are unrelated to the removed inserted duration.

`AudioClipEditorModel` binds a sheet session to exact store generation,
episode/composition, current editability, and shared processing readiness.
An edit followed by Undo or an equal-byte reload still invalidates it. Invalid,
nonfinite, empty, zero, overflowing, day-out-of-bounds, stale-map, or nested
inputs show a refusal and leave the document unchanged. The Apply action reads
live fields, recomputes the complete validated value, then uses the existing
`apply`/`settingAudioArrangement` path once. It does not bypass uncaptured native
state or keep an Undo group open across an await. Undo names are `Insert Intro`,
`Insert & Ripple`, `Edit Inserted Time`, and `Remove Inserted Time`.

Opening/canceling a sheet does not publish, seek, play, or choose routing.
Applying uses the existing presentation synchronization: playback stops,
temporary selection/cycle clears, retained source bins reproject, and words,
markers, IN/OUT display, navigation, and docked/detached review share the same
projection. `reprojectInsertedDisplayTime` preserves a cursor's retained region
offset or clamps a removed offset to the new seam, including preceding sibling
ordering and separate Show cut display offsets. It adds no clip/name/playhead
state to the cached geometry identity. Expanded cut interiors have no production
coordinate and are refused as insertion destinations.

Focused synthetic coverage is in `AudioInsertionEditingTests` (exact value
operations), `AudioInsertionHostedTests` (document/Undo/save/reopen, real
production preparation/audition and source-byte invariance, shared review and
native-state/generation refusals), and `AudioInsertionUITests` (real creation,
preview, retarget, edit/remove, Undo, fixed chrome, production, and negative/
invalid/nesting workflows). Hosted/UI execution requires the approved clean
snapshot/Products identities and a fresh leased ready VM; inherited F5 evidence
does not qualify these new controls. Export is unchanged.

## F8 clip-local linear fade controls

`AudioEnvelopeEditing` prepares reviewable whole-value edits over the existing
`AudioEnvelopeEvaluator`. A Fade In/Out starts at the selected clip's current
composition-aware production playhead, captures its evaluated **current** local
gain, and adds a strictly later ramp endpoint. Duration or absolute program end
time is converted to checked whole output frames within the audible trimmed
interval. Nonfinite times/levels, wrong direction, zero/negative duration,
outside-clip positions, and invalid rational coordinates refuse explicitly.
Target amplitude is finite 0...1; Silence is literal zero, never negative
infinity. Fade In can explicitly initialize zero only at the audible beginning.
Full-to-low-to-zero and zero-to-low-to-full-to-zero sequences use repeated fades.

The endpoint holds to the next existing ramp's start, not merely the next knot.
The overwritten ramp's remaining tail and any subsequent hold knots through
that next start are listed for explicit level replacement when necessary;
every following ramp endpoint remains unchanged. Knots inside
the new interval and crossed existing ramps also require explicit approval.
Outside-window bracketing knots are never removed or edited; when necessary an
audible-end hold knot prevents their slope from leaking into the new held tail.
`AudioEnvelopeEditPreview.confirmed(replacing:)` enforces approval, not just a
disabled button. The sheet revokes approval whenever its draft changes.

Numeric point editing uses current-local whole frames or exact
`numerator/denominator`, including fractional coordinates after native trims.
The selected point, any collision, and reconnected segments are reviewed before
apply/removal. Outside-trim support is read-only. Removing the last point
explicitly restores the empty unity envelope. `settingPoint(atLocalCoordinate:)`
is the rational counterpart of the existing integer API; both translate through
the evaluator's retained origin. Trims, output windows, placement, channel order,
and source support do not change during a fade edit.

`AudioFadeSession` captures clip selection identity, editor lifetime, exact store
generation (including Undo/restore ABA), episode, projection, and originating
window. A native-state document barrier runs before this snapshot; native edits
made afterward still trigger the normal store refusal. Preview never publishes
or restarts playback. Apply uses one guarded `replacingAudioClip`/Undo action.
Cold preparation blocks; verified warm waveform refinement remains interactive.
No new source grants, DSP, nonlinear curves, ducking, track automation, or export
path is introduced. Existing production/offline scheduling evaluates the curve.

`AudioEnvelopeGeometryCache` has a fixed eight-entry LRU budget, following the
existing waveform cache's small retained-entry pattern. Deleted clips are pruned;
panning through distinct clips cannot retain an unbounded history of geometry.
Its key contains envelope/duration, program placement, viewport size/range, and
immutable presentation projection, **not** playhead, selection, names, source
decode jobs, or live faders. The equatable overlay compares this input key before
requesting cached geometry, so playhead ticks do not rebuild even when the visible
clip count exceeds the shared cache budget. Live view geometry leaves with its
viewport; the overlay has no layout or hit-testing role.
Pixel/point reduction is bounded by the viewport with a fixed 8,192-column cap;
exact visible knots are drawn on the curve, and review-only cuts break it.
Waveform drawing equality excludes the envelope, retaining existing raw bins.

Focused coverage: `AudioEnvelopeEditingTests`, the edited-sequence production
case in `SupplementalClipTests`, `AudioFadeGeometryTests`, `AudioFadeHostedTests`,
and `AudioFadeUITests`. The hosted tick test measures actual cache build identity
across playhead publications and unchanged lane/source geometry, not a timing
claim from screenshots. Local package checks and build-for-testing do not qualify
hosted/UI runtime behavior. F6/F7/F8 runtime gates require the combined frozen
tree and approved exact Products/probe/selectors on a freshly ready leased VM.

### Standard legacy WAVE order, separate from raw layout facts

Ordinary bare mono/stereo PCM WAV is a positive Add Audio workflow, not an
unknown-layout negative. The [WAVEFORMATEX contract](https://learn.microsoft.com/en-us/windows/win32/api/mmreg/ns-mmreg-waveformatex#remarks)
unambiguously describes mono/stereo PCM with valid bits equal to the container
size. The existing gateway therefore checks a narrow native-evidenced subset:
legacy tag 1 full-container 16/24/32-bit integer or tag 3/32 IEEE float, 1–2
channels, exact RIFF length, one fmt/data pair, matching native ASBD,
block-align/byte-rate/data/frame accounting, and no unknown/custom channel metadata.
Traversal reads at most 4,096 chunk headers, the 16/18-byte fmt body, and an
optional four-byte fact frame count; it skips data by offset rather than scanning
samples. Known padding/broadcast/ordinary annotation chunks may be skipped.
LIST additionally reads only its four-byte type and accepts INFO/adtl, not unknown
or custom list kinds. Ambiguous, duplicate, malformed, overflowing,
extensible, and multichannel structures receive no legacy evidence.

`LegacyWavePCMChannelOrderEvidence` is intentionally nonserialized, has no public initializer, and is minted only
in `SystemSourceContentIO` from its already-open witnessed read-only descriptor.
`EncodedStreamFacts` and the package cursor carry it outside serialized
`FormatInterpretation`. Raw `ChannelLayoutFacts` stay byte-for-byte unchanged,
including empty/undeclared labels. Only the exactly undeclared layout can use
this evidence; explicitly unknown/custom/reversed/contradictory layouts do not
inherit a default. Explicit supported extensible layouts keep the existing
declared-label path. Cold/warm preparation and every cached read revalidate
the complete raw format/witness/current access and compare this evidence.
The disposable native preparation recipe is v2; format interpretation stays
v1, envelope stays v2, native source-frame origin/count and accepted-map/analysis
semantics are unchanged. This is separate positive native evidence, not a new
historical calibration or holdout qualification.

## F4 verification record (synthetic only, October 30, 2026)

The exact F2/F1/main base was verified before changes. Both independent F3 commits
were integrated in order: `0ae89f2` became `ba6f93f6`, then the required legacy
accepted-timing correction `25d221c` became `37d2d124`. The clean combined
prerequisite baseline reported 563 selected tests across eight package binaries.
The combined F4 run reported 722 selected tests across ten binaries with nine
explicit opt-in skips and no failures, including generated LAME MP3 preparation
and persisted-v1 plain/adaptive compatibility/negative controls.

Load the configured shell environment, use umask 022, and run:

```sh
WW_MP3_LAME="$(command -v lame)" \
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
swift test --package-path Packages/WaveWranglerKit --scratch-path .build/swiftpm \
  --jobs 2 --filter 'WWCoreTests|WWCommonEditTests|WWDecodeTests|WWDerivedTests|WWEpisodeSetupTests|WWMixTests|WWRenderTests|WWSourcesTests|WWPersistenceTests.ShowSchema9MigrationTests|WWAlignPipelineTests.(EnvelopeCompatibilityTests|MapCurrencyTests|ManualTimingIsolationTests|EpisodeSourceAccessTests|GuardTests|EligibilityTests)'
```

The final lifecycle follow-up also passed 97 selected package tests with
`--filter 'WWMixTests|WWRenderTests|ForbiddenAPITests'`. An isolated two-job Debug
app build and `WaveWranglerHostedTests` build-for-testing both succeeded without
launching the development app. A leased **VM ww-ui-1 (Virtualization.framework,
macOS 27.0/26A428, Xcode 27.0/27A266a, 4 vCPU)** development shard then reported
39 selected / 37 passed / 0 failed / 2 explicit timing opt-in skips. It included
`SupplementalProductionHostedTests`, `MixerHostedTests`,
`MixerReviewRegressionTests`, `EpisodeOpenShowBindingTests`, and
`CleanupSourceIdentityHostedTests`; the seven new supplemental adapter methods
all ran. The dirty-tree result is development feedback, not clean-commit
qualification. Its guest artifact is
`~/ww-uitest-runs/f4-hosted-f9ae9c16-20261030-dev2/result.xcresult`.
Final clean-commit qualification and exact commit are recorded in the handoff.
UI/accessibility/performance/holdout suites and physical/acoustic qualification
were not run or inferred from these results.

The working-tree-aware maintenance helper changed only the render record's
`currentTrees`: `Sources/WWRender`
`9de7878720f99808a11f16d55d0928cf3061cc0c` ->
`0faec6501b7df12bc80cf3a603e87a5bb98a9ca0`, and `Tests/WWRenderTests`
`f45827e1228900de7f64f96fed430d42481df88d` ->
`b238df441a71220bf7bdbc4eb197924c3dd6f145`.
Historical record/path/SHA, kernels/specs/policies, seeds and measurements are
unchanged. Historical holdouts still refuse changed historical trees.
