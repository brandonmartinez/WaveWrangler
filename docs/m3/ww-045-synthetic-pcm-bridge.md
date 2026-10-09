# WW-045: provisional common-edit PCM bridge

`WWRender` has an internal, source-free `SyntheticCommonEditPCMPlan` and
`SyntheticCommonEditPCMRenderer`. The plan takes the exact **base** `CommonEpisodeEditMap`,
the `ProvisionalKeyedCutMapping` returned by `KeyedCutMapping.map`, its Shorten/Lift mode,
the ordered lane manifest and structural surveys. It rebuilds and compares the complete
resulting map, including revisions, alignment, origin, rate and removals, then runs
`CommonEditPreflight.check`. The plan also compares the manifest revision and every
survey field against the keyed mapper's retained, validated survey, and refuses any
protected interval intersecting the pending grid in **both** Shorten and Lift.
Neither caller-supplied keys nor this finite structural check
constitute trusted source, protection or human-acceptance evidence. The bridge is
internal to `WWRender` and is **not** wired into app preview, export, source providers
or publication; `CommonEditAttestation.prepare` still refuses.

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

The returned immutable result holds **one** plan and ordered `RenderedChunk` values,
reusable by synthetic preview/export comparisons without two independently selected
maps. Work refuses above the existing 8,192-frame / 16-lane / 65,536-frame-lane
preflight budget; chunk size must be 1–8,192. Cancellation before work, between chunks
and before returning refuses without a result. Tests use only generated asymmetric
audio and explicit silence: negative origin, prior/adjacent and overlapping cuts,
multi-chunk equivalence, Lift padding, exact fades and neighbouring frames, stale
revisions, changed protection after mapping, missing/changed lane content, reversed,
split, altered and adjacent merged fades, protected intervals and mandatory authority
refusal. They do not establish speech preservation, real-media acceptance, a null
preview/export comparison or full-episode size support.

**Open dependency:** #41/#43 require independent complete-source/channel and
protection proof, a current trusted organizer/access witness, accepted cut and review
action, final fade authorization, atomic map/history publication and invalidation, and
an independently reviewed production renderer/provider integration. This preparatory
bridge does not supply any of those gates or change the existing `GroupRenderer` input
and channel-integrity contract.
