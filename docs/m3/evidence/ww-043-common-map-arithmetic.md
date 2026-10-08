# WW-043 provisional common-map arithmetic (synthetic only)

`WWCommonEdit` is a separate package target because the M2 time-map source and test trees are pinned by
`m2-freeze-timemap`; the M3 unit does not change those frozen trees or their gates.

`WWCommonEdit.CommonEpisodeEditMap` is a pure, immutable **frame prescription**, not an accepted edit
or an audio renderer. It consumes an existing validated `AlignedTimelineMap`, an output `NominalRate`,
the padded aligned episode length in that rate's frames, caller-owned alignment/edit revision tokens,
and ordered, half-open removed frame intervals. All tracks use its **same** kept source spans and
output offsets. Output duration is exactly `outputFrameCount/outputRate`; no per-track ripple or
per-track rounding is introduced here. Every input edit endpoint is already on the one common
output grid (zero endpoint quantisation at this layer). The caller must establish that those
endpoints are safe and consistently rounded from its accepted edit coordinates.

Queries compose with the existing epoch/occurrence-aware time map. A removed aligned instant is
reported as `removed` rather than inverted through a seam; gaps and unsupported epochs retain their
original classification, and repeated source occurrences retain separate identities. A point between
grid frames remains exact until one half-up rounding for the returned **position**, with error at
most half an output frame (within the requested one-sample arithmetic bound). A rounded boundary
position can equal the output length and must not be used as an address of a sample. Padding has a
common output position but no fabricated source inverse where an occurrence lacks coverage.
Rebuilding from the same full map/revisions/edit intervals yields an equal value, allowing the
history owner to restore an earlier map without reconstructing removed source samples.

Synthetic deterministic tests cover mixed 44.1/48 kHz rates, a non-unit clock ratio, repeated
source occurrences, two nonadjacent cuts, silent/uncovered padding, a seam, removal partial inverse,
gap/unsupported epoch preservation, all-removed and empty maps, intersecting/out-of-order rejection,
off-grid quantisation and exhaustive small single-interval maps. These are **unit checks**, not
a frozen holdout or real-media acceptance. No holdout was run; future holdout work must first freeze
the gates, recipes, disjoint seeds, truth, strata and counts on a committed clean SHA, then retain
raw records and report nearest-rank p95 and max once per revision.

**Integration dependencies:** Pipeline/WW-028 and WW-045 must supply *human-accepted,
protected-speech-safe* cuts and validate any cuts crossing unmapped regions; bind the revision tokens
to persisted history/invalidation and publish only current revisions; use this one shared map for
every preview/export track including silent tracks. The renderer must implement source selection,
crossfades and common padding, with separate finite proof of zero protected/meaningful/other-speech
loss, fade safety, no-dither preview/export null (at most one PCM step), safe lift alternatives and
deterministic undo/history. None of those audio or human-acceptance gates is established here.

**WW-045 package preflight boundary:** `CommonRenderAdapter.prepare` currently refuses with
`organizerAuthorityUnavailable`. Its internal, synthetic-only `inspectSynthetic` checks an explicitly
listed inventory against distinct occurrence/channel lane keys (including full-episode, timed explicit
silence), full-length declared aligned backing, protection-list presence, removal-list consistency,
overlapping fades and fade-footprint intersection with every lane's declared protected frames. A
successful synthetic inspection yields the same immutable `CommonEpisodeEditMap` value for prospective
preview/render prescriptions, not audio, a publication token, or proof that the caller's claims are
true. The synthetic preflight accepts empty protection arrays as *test inputs*, not as evidence of an
actual speech survey.

**Provisional organizer inventory (stacked M3 unit):** `ProvisionalLaneInventory.inspect(episode:map:)`
derives immutable occurrence/channel requirements from *every* map placement and the episode's
channel-count metadata. It includes Primary, Backup, other-speaker and unassigned channels (including
channels a later producer might verify as timed silence); repeated uses of one source have distinct
occurrence keys and epoch lists. Each occurrence must use exactly its source's stated placement epoch,
and every map epoch must be used by a placed occurrence; an absent placement epoch, an occurrence
spanning another epoch, or an unplaced map epoch is refused. It refuses absent/unplaced/duplicate
sources, changed groups/epochs, unknown or out-of-range channel counts/assignments, channels
assigned more than once across speaker roles (including duplicate primaries and backups), mismatched
map inputs, and an unaccepted or different persisted alignment revision. `sourceRole` describes the
whole recording, not a channel's Primary/Backup status for an individual speaker. The snapshot is
**provisional**: a caller can construct an `Episode`, and its reported channel count/role is
metadata, not decoded proof.
It has no promotion path to `CommonRenderBinding`; `prepare` still refuses unconditionally with
`organizerAuthorityUnavailable`. Focused WWCommonEdit tests use synthetic fixtures only.

**Producer contract to open the gate:** an organizer-owned, persisted and revision-checked producer
must enumerate the complete episode from canonical sources and every uniquely keyed occurrence/epoch,
not from an editor-supplied array, completeness boolean or a protection list. It must match the
accepted map and current source identity/content/format revisions, supply independently verified
full-length aligned backing *or* an explicitly timed and evidenced silence interval for each lane,
and refuse any absent/ambiguous channel, epoch, coverage, source or other-speaker/Backup state.
A separate human decision/protection producer must bind the accepted edit and protection survey to
those exact revisions: an empty protected interval list without a completed authoritative survey is
**unknown**, not safe. For each cut it must check both exact `qStart` and `qEnd` against each occurrence's
partial inverse, including gaps/unsupported interior coverage, quantise endpoints once on the common
frame grid, and validate the **final merged fade footprint** against protected/meaningful speech on
every lane. A single adapter must use that same accepted map for every preview/render lane, then
recheck episode/map/source/decision revisions at **atomic NSDocument publication**. The current M2
alignment job renders one group into segments; neither it nor this inventory establishes verified
backing, protection, human acceptance, full inverse coverage, renderer behavior or publication.
Until those producers and gates exist, no product preview, export, shorten/lift, real-media proof or
no-dither null claim is made here.

**Separate WW-045 source-backed diagnostic (stacked on draft #290):**
`ProvisionalSourceBackedProof.inspect` first derives the entire occurrence/channel inventory above,
then uses `WWDecode.SourceDecoder` to read each distinct source through its read-only content gateway.
It refuses absent/extra source locations, decode failures or changes during decode, missing map-input
format revisions, content-digest inputs that it cannot re-verify, inexact decoded sample formats,
channel/rate/frame-count drift and non-finite samples. Repeated placements retain separate keys even
when one source is decoded once. Its immutable result contains the decoded format/fingerprint for
every lane and identifies channels that were **exactly digital zero for the whole verified decode**;
it contains no fabricated aligned audio asset, cut permission or publication token. A caller-supplied
path is still a location hint, not an organizer-attested identity; no persisted source/content revision
is available to bind that path to the accepted M2 map or to recheck it after inspection.

The recipe projects each complete source-frame span through its supported affine clock pieces using
exact rational arithmetic; it refuses gaps, unsupported pieces, overlapping mapped coverage, missing
or extra episode-grid coverage and non-invertible cut endpoints for any occurrence. Ordinary
shorter/longer source placements and padding **abstain** until timed authoritative backing/silence
is available; they are not interpreted as zero-filled samples. All removed endpoints are
already on the ONE common output grid. Every nonzero decoded source sample, on *every* channel, is
treated as potentially protected speech; a removal or the union of the supplied final fade footprints
touching its exact projected interval is refused. Explicit known-protected intervals (including
digital silence) are **additional vetoes only**: a missing or empty list is *not* an authoritative
speech survey and can never authorize a render. This unusually conservative digital-zero rule may
abstain on harmless noise, and neither a zero sample nor a supplied fade extent proves a human
decision, intentional silence policy or actual renderer footprint. Synthetic WAV tests cover
Primary, Backup, unassigned channels, repeated uses, 44.1/48-kHz grid quantisation, source/format
drift, unsupported coverage, nonzero speech proxies, protected silence and overlapping fades.

The current nonnegative common-grid domain refuses negative-leading placements rather than silently
dropping them. **#302** is the separate signed-grid correction, required before these coordinates
could be used as production proof; this unit neither reproduces nor revises its rejected predecessor.
**#304** is the separate renderer-budget revision and is not a rendering or backing guarantee for
this proof. Before any product shortening, the organizer must persist and attest source revisions,
verify the human-accepted edit and *complete* protected/meaningful/other-speech survey (including
silent intervals), and couple the final renderer fade footprint, all-lane shared render, and atomic
current-revision native publication. `CommonRenderAdapter.prepare` remains unconditionally
`organizerAuthorityUnavailable`; no ShowDocument/store/restore code or frozen M2 tree is changed.
