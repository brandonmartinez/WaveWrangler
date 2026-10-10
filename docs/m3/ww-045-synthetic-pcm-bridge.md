# WW-045: provisional common-edit PCM bridge

The separate, unexported `WWSyntheticCommonEditPCM` package target has an internal,
source-free `SyntheticCommonEditPCMPlan` and `SyntheticCommonEditPCMRenderer`.
Neither the frozen M2 `WWRender` source nor its test tree is changed. The plan takes
the exact **base** `CommonEpisodeEditMap`,
the `ProvisionalKeyedCutMapping` returned by `KeyedCutMapping.map`, its Shorten/Lift mode,
the ordered lane manifest and structural surveys. It rebuilds and compares the complete
resulting map, including revisions, alignment, origin, rate and removals, then runs
`CommonEditPreflight.check`. The plan also compares the manifest revision and every
survey field against the keyed mapper's retained, validated survey, and refuses any
protected interval intersecting the pending grid in **both** Shorten and Lift.
Neither caller-supplied keys nor this finite structural check
constitute trusted source, protection or human-acceptance evidence. The bridge is
internal to its package target and is **not** wired into app preview, export, source providers
or publication; `CommonEditAttestation.prepare` still refuses.

This current-main reintroduction preserves the merged #377 selected-Primary/Backup
classification and the #433 refusal-only protected removal/requested/merged-fade
policy. #360's per-cut audit is historical data, not fresh human authorization.
The closed-unmerged #414 bridge is design input, not a passed integration gate:
its exact-head working-Mac `scripts/test.sh` exited 1 at the unchanged
WWPersistence quiescent-checkpoint timing gate (p95 2.0357775 s > 2.0 s),
before the remaining timing/native tests. This branch needs its own independent
source review and separately scheduled exact-head full run; focused generated
PCM checks do not replace either.

The already-aligned planar input has one full original-grid buffer per declared audio
or intentional-silence lane, in keyed manifest order. It cannot read a recording or
decode media. Input lengths, finiteness and explicit zero padding are checked before
processing. Shorten copies exactly the common map's kept spans to one output grid,
including silence, so adjacent prior removals and a new removal are applied once.
Lift leaves the map duration unchanged and emits exact zero in the reserved cut grid
for every lane. Neither mode independently rounds cut endpoints or source durations.
Only exact final merged grid fade footprints from the keyed mapping may be processed.
Adjacent footprint spans form one continuous gain envelope, never independent resets;
each resulting envelope must contain its keyed requested out/in side, have exactly
that side's direction, and match the complete merged interval. Unidentified older
footprints refuse rather than guessing their gain direction. Envelopes stay outside
cuts and removed spans and pass preflight's coverage and protection checks. The synthetic
linear fade-out uses `(length - position - 1) / length`, and fade-in uses
`(position + 1) / length`; all frames outside envelopes are bitwise copies.

The returned immutable result holds **one** plan and ordered `SyntheticPCMChunk` values,
reusable by synthetic preview/export comparisons without two independently selected
maps. Work refuses above the existing 8,192-frame / 16-lane / 65,536-frame-lane
preflight budget; chunk size must be 1–8,192. Cancellation before work, between chunks
and before returning refuses without a result. Tests use only generated asymmetric
selected-Primary audio, an excluded Backup role with no PCM input, and explicit
silence: negative origin, prior/adjacent and overlapping cuts,
multi-chunk equivalence, Lift padding, exact fades and neighbouring frames, stale
revisions, changed protection after mapping, missing/changed lane content, reversed,
split, altered and adjacent merged fades, protected intervals and mandatory authority
refusal. The excluded Backup has no survey, keyed footprint, or PCM channel;
tests refuse missing role claims or a changed exclusion. No Backup file is
verified or authorized for M3 cut proof, preview, or render. These tests do not
establish speech preservation, real-media acceptance,
a null preview/export comparison or full-episode size support.

**Open dependency:** M3 #41/#43 are rescoped to admitted selected-Primary tracks.
Backup files must not be opened in M3; the product must visibly flag
`backup not verified; excluded from cut proof` and fail closed rather than silently
include Backup in cut proof, preview, or render. Primary source immutability,
protected-speech checks, a current trusted organizer/access witness, accepted cut
and review action, final fade authorization, atomic map/history publication and
invalidation, and independently reviewed production renderer/provider integration
remain hard gates. Positive Backup access and all-lane source/no-revoked-open proof
move to M4 #420 with separate exact Backup consent. This preparatory bridge does
not supply any of those gates or change the existing `GroupRenderer` input and
channel-integrity contract. Its `SyntheticPCMChunk` is not a production
`WWRender.RenderedChunk` or a render/export admission.
