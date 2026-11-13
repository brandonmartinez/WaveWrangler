# Program timeline

`WWCommonEdit` owns immutable Sendable `ProgramTimeline`, `ProgramComposition`
and `AudioEnvelopeEvaluator` snapshots. These are geometry, not source access,
playback, document services or recorder-clock edits. Validated edits use the
shared canonical transaction and Undo path.

## Coordinates and authority

The chain is native source frames through exact accepted source/group maps to
**original-aligned dialogue -> merged common cuts -> explicit inserted time ->
final program**. Edit/program coordinates are signed integer 48 kHz frames
within the signed-day envelope. Asset trims are half-open native frames;
envelope coordinates may be exact rational positions.

Construct `ProgramTimeline(episode:dialogueFrames:)` using complete original
aligned coverage from the current accepted-map context. Coverage is required
with accepted alignment and forbidden without it. It is not per-source
coverage, clock approval or a live source check. Audio-only programs do not
invent an accepted map.

| API | Contract |
| --- | --- |
| `dialoguePosition(atAlignedFrame:)` | Mapped sample, removed interval/seam, or outside coverage; a cut seam is not a sample |
| `inverse(atProgramFrame:)` | Dialogue, insertion region/offset, or outside coverage; inserted audio has no dialogue inverse |
| `project(_:)` | Placement, cut-seam clamp, or review requirement; placement need not lie within finite sample coverage |
| `segments(in:)` | Complete exact partition into kept dialogue, insertion-only and outside-dialogue intervals |
| `composition()` | Atomic complete clip projection and extent; invalid/stale clips never silently disappear |

A valid map-bound placement point may be outside the finite dialogue hull;
that does not extrapolate the source clock or authorize reading samples.
An extent is a hull, not continuous sample availability.

Cuts merge overlap and adjacency once. Rebuild from original saved anchors
rather than accumulating subtractions. A start inside `[start,end)` clamps to
the seam while retaining the whole clip; the exclusive cut end belongs to later
dialogue. A clip spanning a cut is not shortened. Production collapses **all**
active cuts regardless of view, mute or Solo.

Show Cut is a separate review projection: expanding/hiding one cut changes
device-local presentation, not saved anchors, pins, Undo or production audio.
Its interior cannot be used as a production insertion destination. Keep
`AudioTimelineProjection` indexes immutable and resolve the live projection
again at pointer/edit time.

## Anchors, pins and insertions

Dialogue anchors bind SHA-256 over the **entire canonical `TimeMapVersion`**,
not only its revision. A same-revision content change requires review.
Stale regions refuse construction because they affect the complete projection;
stale clips refuse complete composition rather than being omitted.

- `.programOrigin` is the cut-independent pre-insertion grid.
- `.dialogue` follows current cuts and insertions from its saved aligned point.
- `.absolute` pins a clip in final program time. Absolute region anchors refuse.
- `.insertion` follows a named region with a checked relative start.

Resolve regions by base boundary, then saved `insertionRegions` array order.
Even distinct original points collapsed to one cut seam use that order.
Ordinary unpinned starts at the boundary follow every insertion there.
Regions are positive, half-open, stable-ID intervals with no nesting.
Clips may overhang regions; inserted duration never splits, stretches or crops
their source support.

Use `unpinnedAnchor(atProgramFrame:)` on the **current** projection when placing
after edits. It removes current insertion offsets then inverses merged cuts,
or returns a region-relative anchor in an insertion. Only a program with no
accepted binding uses program origin. Invalid inverses refuse, not fallback
to zero/origin. Explicit pin/unpin/reconcile helpers preserve resolved position;
old origin anchors are never automatically rebound after alignment.

For dialogue `[0,10)` seconds, an unpinned clip originally at 12 moves to 10
after cutting `[2,4)`; an absolute 12-second pin stays 12. A new unpinned clip
placed at final 12 **after** the cut binds original point 14 and stays at 12
until another edit. Neither outside-hull point implies dialogue samples there.

`AudioInsertionEditing` revalidates the episode and complete composition.
Intro defaults to the earliest retained dialogue/region/unpinned clip, not
automatically zero; pins do not pull it earlier when ordinary content exists.
Insertion at an exact region start goes before that array entry. Moving a
region measures destination in the program **with itself removed**.
Shortening clamps only relative starts outside the new region to its new seam.
Removal retains all clips and inverse-anchors attached starts at the old seam,
respecting preceding/following siblings. Pins remain fixed.

Opening/canceling an editor is preview-only. Apply recomputes from live fields,
requires exact store generation/window/episode/editability and native-state
currency (including Undo/equal-byte reload ABA), then publishes once.
Playback stops and presentation reprojects consistently across waveforms, words,
markers, clocks and detached review. Do not retain an Undo group across awaits.

## Clip samples and envelopes

`ProgramAudioClip` keeps immutable source identity, a distinct occurrence ID,
native trim, channel order, envelope and program placement. Ordinary duration
is checked `CEIL(nativeLength * 48000 / nativeRate)`.
`outputWindow` retains an exact subrange of that nominal 48 kHz grid so split/
crop does not independently round two new native supports.

Source position is native trim start plus
`(outputWindow.offsetFrames + localProgramFrame) * nativeRate / 48000`.
The exclusive program endpoint is not scheduled. At 44.1 kHz, independently
rounding native split frame 1 produces 2+479=481 output frames instead of 480;
retaining nominal output split 2 produces 2+478=480 with the original phase.
Do not replace sample-preserving windows with approximate second values.

`AudioEnvelopeEvaluator` uses exact clip-local coordinates, linear amplitude
interpolation, finite levels 0-1 and literal zero. Empty is unity and endpoint
levels hold. Retain supporting knots outside a trim/window; they can determine
the audible slope and are read-only in that window. Placement changes do not
rewrite source-local envelope coordinates.

`AudioEnvelopeEditing` prepares a full reviewed value. Fades start at the current
clip-local playhead and end strictly later within audible output. Start/end
levels are editable; a custom start can introduce an explicit step while
preserving preceding output. Duration/end-time controls share checked whole
frames. Numeric points also support exact numerator/denominator positions.

Overwritten knots, crossed ramps and changed holds require explicit replacement
approval; changing the draft revokes it. Preserve subsequent ramp endpoints and
outside-window support, adding an audible-end hold when necessary to avoid
leaking a later slope into the tail. Removing the last point explicitly restores
unity. Preview/apply uses exact session/generation/selection/window tokens and
one canonical Undo action, not persistent preview state or a second DSP path.

## Supplemental import and scheduling

The Add Audio picker defaults to overlay. Timeline drops default to sequential,
with explicit order/destination/position and an Overlay choice in review.
Every selected file qualifies before one `settingAudioState`/Add Audio
transaction. Sequential placement uses each checked duration and a fresh inverse
anchor; the batch itself never inserts time.

Drops accept location-only exact file URLs. The live whole `DropSession`
count, ID and phase are authority, not a filtered provider roster or maximum
observed count. Exit/disappearance/consume invalidate snapshots; ended IDs
cannot replay. Mixed payloads refuse atomically. Hover does no header read,
preview or duration guess. Folders are reported/skipped, never enumerated;
web URLs, promises and recorder-row payloads refuse. Ambiguous/header-only/
review-cut positions do not silently clamp to zero.

Use the full canonical physical identity roster (volume UUID plus persistent
file ID) to detect aliases. Missing identity is a named repair requirement,
not an empty match set; known nonmatching recordings may remain offline.
Any active recording/unknown-purpose match blocks asset reuse.
Same-episode verified supplemental reuse keeps `SourceID`; cross-episode
explicit import creates a new episode-owned logical source/access record.

`PendingAudioImport` is an opaque live engine/scan/candidate token. Re-admit both
the saved original and dropped location with current geometry/witness/access
generation. Prepublication requires the exact canonical generation; after
publication only the single owned batch is allowed. Conditional atomic access
adoption preserves later/regranted records. Failure after publication leaves
blocked repairable references and a visible relink/Undo explanation.

Native preparation uses bounded 16,384-frame tiles/65,536-frame windows, a
1 GiB total cap and exclusive actor/root ownership. Publish the manifest last
and clean incomplete owned work; never allocate whole-source PCM or treat
geometry as authorization. Channel layout is not inferred from count alone.
Narrow legacy WAV evidence is gateway-minted/nonserialized; codec-cookie
evidence is distinct from raw channel labels. Preserve MP3 envelope-version
compatibility and explicit acceptance recipes, not digest fallback.

Supplemental waveforms use current native preparation/admission even on warm
hits. Drawing and native accessibility controls share immutable clip placements;
the pointer-transparent AX canvas must expose visible clip bounds, not a lane.
Import/placement changes invalidate processing, not original recording alignment,
raw transcript provenance or unrelated source measurements.

## Production bounds and clocks

`Episode.productionRange` stores optional start/end anchors and `restrictSpeech`
(default false). Neutral settings remove the optional value. These are canonical
audible edits with Undo, not view preferences or changes to original IN/OUT keys.

`EpisodeProductionProjection` is shared by production, boundary editors,
markers and clocks. It refuses mismatched composition, stale explicit Speaker
In/Out, unresolved anchors and reversed bounds. Automatic bounds include
projected speaker extents, every clip and intentional inserted time,
independent of listening controls. Audio-only episodes use their arrangement;
truly empty episodes have no playable range even with manual saved edges.
The media hull is not necessarily the finished episode range.

Speaker In has following-sample insertion affinity; exclusive Speaker Out is
before insertions at its boundary. Manual anchors retain normal placement
affinity. Restrict Speech hard-gates speaker input before inserts, then applies
one 240-frame/5 ms de-click on the allowed side after speaker processing/PDC.
Speaker tails cannot leak past Speaker Out; assets are unaffected and shared
master decay may continue with music until Episode End. Stop immediately
invalidates/silences all output instead of draining a tail.

| Clock | Meaning |
| --- | --- |
| Episode Time | Program relative to Episode Start; can be negative |
| Timeline Time | Unchanged signed final program coordinate |
| Speaker Time | Edited dialogue elapsed from Speaker In, excluding cuts/insertions; unavailable outside dialogue sample coverage |

Clock inverses refuse unavailable positions rather than selecting another clock.
The primary display accepts signed `HH:MM:SS.mmm` or seconds. Changing a clock
does not seek or move media. Source Audition is labeled Source Time; expanded
review coordinates are not production clock inputs.

Production Mix is the default listening mode. Playback/selection/cycles respect
Episode Start/End including deliberately included silence. Hear Removed Audio
and Hear Cut with Context explicitly choose diagnostic Source Audition and reveal
only that cut; saved state and other cuts remain intact.

Control-bar configuration is versioned app-local state shared by episode
windows, not show content. Individual controls/group order, clocks, labels and
readouts migrate without silently resetting choices; malformed configuration
stays visible until explicit Restore Defaults. Per-episode viewport state is
also local. Neither changes routing implicitly.
