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
| `project(_:)` | Placement positions: `.placed`, `.clampedToCutSeam`, `.reviewRequired`, or `.outsideDialogueCoverage`. The terminal dialogue endpoint is a valid placement but not a sample. |
| `segments(in:)` | Exact contiguous request partition into kept dialogue spans, insertion-only intervals, and explicit outside-dialogue intervals. |
| `composition()` | Atomic complete clip projection and bounds; stale/outside-dialogue clips refuse the result, never disappear from a successful extent. |

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

- Dialogue region anchors use the merged cut map. Program-origin regions use a
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
for placement after existing edits. It returns a current map-bound original
dialogue anchor, a region-relative anchor, or a pre-insertion program origin for
uncovered space. This prevents applying earlier cuts/insertions twice.
`pinnedAnchor(for:)` and `unpinnedAnchor(for:)` preserve resolved position;
review-required anchors refuse these helpers. Submit the returned anchor through
F1's `replacingAudioClip`/compound operation and normal shared-store Undo.

Bindings use F1's SHA-256 over the **entire canonical `TimeMapVersion`**, not a
revision number or pipeline/cache object identity. A same-revision byte change
requires review. Stale regions refuse construction because they affect the
entire projection; stale clips have individual review outcomes and refuse
complete composition.

## Source scheduling and extents (F4/F5/F8)

`ProgramAudioClip` retains the exact original clip, asset geometry, and separate
`programFrames`. Duration is F1's checked
`CEIL((nativeEnd-nativeStart) * 48000 / nativeRate)`. Clips sharing a source retain
distinct clip IDs, trims, channel orders, envelopes, and placements.
`sourceChannels` expands nil to native channel order without changing saved state.
`sourcePosition(atProgramFrame:)` returns exact native position
`nativeTrimStart + localProgramFrame * nativeRate / 48000`, or outside coverage.
The exclusive program endpoint is not scheduled; the final CEIL-owned sample's
native position is still strictly inside the trim.

`ProgramComposition.programFrames` includes all dialogue spans, all regions, and
all clips, independent of visibility, mute, Solo, and live faders. Nil means truly
empty. Overflow, bounds violations, invalid shapes, unsupported anchors, and
review requirements are typed refusals. No live controls are inputs to projection.

F4 must freeze normal `EpisodeProcessingInputs`, current accepted timing, live
source witnesses and decoder interpretation in its own recipe. Program placement
does not reset/reanalyze recordings or invalidate original transcript/word/source
waveform partitions. F3 preparation is a separate dependency; the current
`MixerRecipe` refusal remains until actual clip routing is integrated.

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

### Remaining SRC/frame-ownership obligation

This is **not** a claim of sample-for-sample concatenation of independently
CEIL-rounded native splits. A 44.1 kHz `[0,441)` trim owns 480 program frames.
Splitting at native frame 1 yields independently rounded durations 2 and 479,
total **481**, not 480. The leading sample positions are native `0, 147/160`;
the trailing first position is native `1`. Appending the trailing clip at
program frame 2 is not the unsplit native position `294/160`.

The regression preserves that discrepancy explicitly: for a 0-to-1 ramp over
480 frames, the trailing first gain is `1/441`, not the original frame-2 gain
`1/240`. F4 must decide and verify global SRC phase/frame ownership for any
sample-preserving split operation. F2 neither hides the difference by dropping/
duplicating a frame nor changes F1 duration semantics. Envelope correctness and
DSP sample-grid continuity are separate obligations.
