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
