# WW-043 provisional common-map arithmetic (synthetic only)

`WWCommonEdit` is a separate package target because the M2 time-map source and test trees are pinned by
`m2-freeze-timemap`; the M3 unit does not change those frozen trees or their gates.

`WWCommonEdit.CommonEpisodeEditMap` is a pure, immutable **frame prescription**, not an accepted edit
or an audio renderer. It consumes an existing validated `AlignedTimelineMap`, an output `NominalRate`,
an **explicit signed** `alignedFrameOrigin` and nonnegative `alignedFrameCount` at that rate,
caller-owned alignment/edit revision tokens, and ordered, half-open removed frame intervals. The
aligned domain is `[alignedFrameOrigin, alignedFrameOrigin + alignedFrameCount)`; its frame indices
are absolute relative to the M2 reference's aligned `t=0`. For example, a 48 kHz non-primary map
`t=n/48000-0.1` needs an origin of at most `-4800` to retain its first 4,800 source frames; increasing
the count with origin `0` only pads the *end* and still drops that leading placement. Callers must
choose a domain that covers every intended mapped placement, including leading negative time and
common padding. This provisional unit does not discover the required episode envelope or infer
speech safety from it.

Removal endpoints and `KeptFrameSpan.alignedStart/alignedEnd` are absolute signed indices on that
same grid, while `KeptFrameSpan.outputStart`, output frame queries and `outputFrameCount` start at
zero. All tracks use the **same** kept spans and output offsets. Output duration is exactly
`outputFrameCount/outputRate`, independent of the signed origin; no per-track ripple or per-track
rounding is introduced. Every input edit endpoint must already lie on this grid (zero endpoint
quantisation at this layer); callers must establish safe, consistent rounding when converting
accepted edit coordinates to these indices. The count is limited to the M2 `maxFrameCount`; the
signed origin plus count must fit `Int64`. An empty/out-of-domain removal, an overlapping or
out-of-order removal, a count outside that limit, or an overflowing end is explicitly refused.

Queries compose with the existing epoch/occurrence-aware time map. For an instant inside the signed
domain, a removed aligned instant is reported as `removed` rather than inverted through a seam;
instants outside it return `outsideCoverage`, including an off-grid tick before the start and the
exclusive end. Gaps and unsupported epochs retain their original classification, and repeated
source occurrences require an explicit occurrence ID for each inverse; the map never picks one
ambiguously. A point between grid frames remains exact until one HALF-UP rounding for the returned
**position**, with error at most half an output frame (within the requested one-sample arithmetic
bound). A rounded position near the exclusive end can equal the output length and must not be used
as a sample address. Padding has a common output position but no fabricated source inverse where
an occurrence lacks coverage.
Rebuilding from the same full map/revisions/edit intervals yields an equal value, allowing the
history owner to restore an earlier map without reconstructing removed source samples.

Synthetic deterministic tests cover mixed 44.1/48 kHz rates, a non-unit clock ratio, repeated
source occurrences, negative-leading no-removal roundtrip, positive and negative offsets, two
nonadjacent cuts across zero, silent/uncovered padding, a seam, removal partial inverse, signed-domain
gap/unsupported preservation, signed endpoint overflow and removal bounds, off-grid limits and
quantisation, all-removed and empty maps, intersecting/out-of-order rejection and exhaustive small
single-interval maps. These are **unit checks**, not
a frozen holdout or real-media acceptance. No holdout was run; future holdout work must first freeze
the gates, recipes, disjoint seeds, truth, strata and counts on a committed clean SHA, then retain
raw records and report nearest-rank p95 and max once per revision.

**Fresh-main integration (2026-10-08, Macatron):** The production source is the exact reviewed
`a171a93cd81c15d5366225019922d68739b4e0b0` blob from draft #302, not a merge of rejected
#261. Its 11 reviewed tests are retained, with one additional direct no-removal source-frame-zero
roundtrip. Before restoring the reviewed arithmetic, those two signed-origin regressions were run
against the old zero-based arithmetic with the new API shape: both failed (source frame zero inverted
as frame 4,800; the negative-side cut was refused). With the reviewed source restored, 12/12 common-map
tests and 10/10 active time-map checks passed at four jobs/workers; the two gated calibration/holdout
cases were skipped, not run. `scripts/build.sh Debug` succeeded at four jobs. Working-Mac starting
one-minute loads were 17.68 (red), 8.45 (focused green), and 8.98 (build), all below 24.
The final clean pushed head still needs independent review and the coordinator's full exact-head
`scripts/test.sh`; no GUI, real media/model/network, or product acceptance was exercised here.

**Integration dependencies:** Pipeline/WW-028 and WW-045 must supply *human-accepted,
protected-speech-safe* cuts and validate any cuts crossing unmapped regions; bind the revision tokens
to persisted history/invalidation and publish only current revisions; use this one shared map for
every preview/export track including silent tracks. The renderer must implement source selection,
crossfades and common padding, with separate finite proof of zero protected/meaningful/other-speech
loss, fade safety, no-dither preview/export null (at most one PCM step), safe lift alternatives and
deterministic undo/history. None of those audio or human-acceptance gates is established here.

**Provisional structural preflight (separate M3 unit):** `CommonEditPreflight.check` takes a
caller-supplied `CommonEditLaneManifest` and one grid survey per declared audio or intentional-silence
lane. Both the manifest and the map's caller-owned revision tokens are **untrusted inputs**: matching
them does not prove organizer completeness, current source identity, device-local grant, access,
consent, decoded backing, protection-survey accuracy, cut acceptance or render readiness. The
finite check compares every supplied manifest lane to exactly one survey, requires every mapped
occurrence to have a declared audio lane, validates source/occurrence/channel shape and ordered
in-domain intervals, inspects every grid frame (including negative origin and silence) for exact
common-map round-trip and per-occurrence inverse/coverage, refuses gaps/unsupported inverses,
protected removals and unsafe final merged fade spans. A missing survey, duplicated lane, missing
grid coverage or >8,192-frame domain refuses; this limit is deliberately **not** a real-episode
qualification. Off-grid rounded end positions remain positions, not sample addresses.
`CommonEditAttestation.prepare` always refuses, including after structural success. No renderer,
accepted-map history or preview is published by this package. The synthetic tests exercise
structural success followed by mandatory refusal and negative mismatched supplied keys/revision,
duplicate/missing surveys, negative-grid/coverage, unsupported inverse, protected cut and
merged-fade cases. They do **not** decode a source or verify a live grant.
The corrected inverse quantizes on the source-frame grid for mixed sample rates; protection and
final-fade containment treats adjacent validated intervals as contiguous but never bridges a
positive gap. Synthetic tests exercise both mixed-rate coverage and adjacent spans, plus negative
unavailable-source-frame and gap refusals.

**Interface decision needed before removing that refusal:** Mac must supply a fresh, trusted
organizer/source-access witness for every selected Primary, Backup, other-speaker and explicitly
silent lane, and own atomic common-map/history publication with preview invalidation. Alignment
must bind accepted-map *content*, current source/format revisions and each occurrence's complete
footprint/inverse to that witness. Independent whole-lane protected-speech surveys, complete
final merged fade proof and a person-initiated review action remain hard prerequisites. Existing
`WWCutPolicy` manifest/review-action constructors are internal to that module; this preflight
neither bypasses them nor grants new access to unselected audio. No #40/#41 acceptance claim follows
from the provisional result.
