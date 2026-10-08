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

**Integration dependencies:** Pipeline/WW-028 and WW-045 must supply *human-accepted,
protected-speech-safe* cuts and validate any cuts crossing unmapped regions; bind the revision tokens
to persisted history/invalidation and publish only current revisions; use this one shared map for
every preview/export track including silent tracks. The renderer must implement source selection,
crossfades and common padding, with separate finite proof of zero protected/meaningful/other-speech
loss, fade safety, no-dither preview/export null (at most one PCM step), safe lift alternatives and
deterministic undo/history. None of those audio or human-acceptance gates is established here.
