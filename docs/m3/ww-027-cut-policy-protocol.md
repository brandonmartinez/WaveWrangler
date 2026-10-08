# WW-027 / WW-028: conservative cut-policy precursor and measurement protocol

**Status:** protocol fixed in this commit; synthetic policy precursor only. No recognition, media,
calibration, disjoint holdout, human listening, or precision result has been run or claimed here.
Refs #21 #25 #27 #41. The pure `WWCutPolicy` target is not connected to the app, renderer, or
`WWCommonEdit`; it cannot activate or render a cut. The latter's exact rounded pre-edit aligned-output
frame endpoints (`qStart`, `qEnd`) must be supplied by an Alignment-owned adapter at output rate `R`.
Do not use native source duration as the common ripple. Until the adapter and every-lane renderer
integration are reviewed, these tests establish refusal behavior only, not full edit safety.

## Frozen prospective measurement rules (no holdout attempted)

Freeze an immutable revision of the eligible primary-track manifest, source/model/format/asset/map
revisions, transcription and protection methods, script/annotation rubric, stratification, matching
algorithm, exclusions, count targets, seeds/split, thresholds and generator-tree pin **in a committed
registry before the first disjoint holdout case is processed**. This document fixes the rules and gates,
but is not that registry: no annotated/calibrated cohort, eligible media manifest, generator pin or
independent truth exists. Never convert these synthetic unit cases to a claimed held-out population.
Calibration may tune a proposal rule on a separate training set; only a new pre-holdout registry
revision may change it. Run holdout once per frozen revision and report every eligible, failed, excluded,
timed, untimed and abstained case; retain failed runs, and never lower gates after seeing results.

Eligible reference words are independent human-annotated English speech words on an explicitly selected,
locally authorized Primary source/channel, in a named occurrence and epoch with supported alignment.
The manifest freezes inclusion/exclusion before inference. Each eligible reference word contributes **two**
observations (start and end) to the denominator, even if omitted by recognition, missing timing,
hallucinated, unmapped, or unsupported. Exclude only a predeclared, independently verified invalid
reference recording/annotation or out-of-consent track; report excluded counts/reasons, never remove a
difficult but eligible word after recognition. Require at least **1,000 reference boundary observations**
(at least 500 reference words) in disjoint holdout, across the predeclared clean, low-volume, overlap,
disfluency and epoch-edge strata. Freeze each stratum's minimum count and timing-coverage minimum from
calibration **before** holdout; until those numeric minima are in the registry, the gate is NOT READY.

Match a recognized token to at most one reference token and vice versa, within the same
source/channel/occurrence/epoch, by a frozen monotonic token alignment with a predeclared normalization
and adjudication rule; unsupported or ambiguous matches are failures, not a nearest-neighbor timestamp.
For a matched word, count each independently supported start/end boundary; a missing/unsupported
boundary remains a denominator failure even if the other boundary is supported. Report timing coverage
`supported matched boundaries / all eligible reference boundaries` per stratum and overall; report
omissions, insertions/hallucinations, unsupported and ambiguous boundaries separately. Compute absolute
boundary error **only for supported matched observations** and report nearest-rank p95 (`ceil(0.95*n)`)
and max; p95 must be **<=100 ms**, while coverage and each frozen stratum minimum must also pass.
Never label a recognition confidence as a timing proof or cut authorization. If an engine lacks
confidence, record `absent`, not zero or an invented probability.

Independent reviewers label each proposed interval as safe contextual filler or false accept under
the pre-frozen rubric using the whole affected-lane context, including meaningful uses, overlap,
other-speaker speech, backup tracks and final merged fades. Holdout requires **at least 300 emitted
proposals**; precision is `safe proposed intervals / all emitted proposals` (including blocked,
untimed, hallucinated and unsupported proposals as false accepts if they were emitted as eligible
cuts). Gate precision **>=98%** and its **95% Wilson score lower bound >=95%** (two-sided interval,
`z=1.959963984540054`). Report numerators/denominators and the interval, with recall secondary.
Require zero cuts admitted from hallucinated/unsupported/missing boundaries, zero protected-source
frame loss, zero clipped meaningful or other speech in the finite tested set, and objectionable cuts
<=5% among independently listened eligible outputs; do not claim the listening gate without authorized
listeners. All uncertain cases abstain or remain for explicit review. Unknown transcription on an
otherwise audio-bearing lane is not intentional silence.

Holdout units must be disjoint from calibration at the **recording/episode** level; changing only
seeds or adjacent chunks of the same episode is not an independent holdout. If available approved
material cannot satisfy counts, strata, disjointness or independent truth, report **NOT RUN/INSUFFICIENT**,
never a passed gate. The user's approved disposable copy permits local selected-Primary analysis
only; no such content is accessed in this precursor. Before any actual-media run, the owner must
define and freeze the precise selected-Primary source/channel/occurrence allowlist locally, aggregate
counter schema and disclosure/retention protocol. No media, identifying paths/names, token text,
transcript, excerpt or model body goes into Git, an issue, PR or external service. Backup analysis
is never authorized by its participation in common-map proof.

## Implemented precursor boundary

Every word in a proposed anchor has explicit supported start/end source frames; missing, unsupported
and hallucinated timing are distinct. Meaningful, overlapping, uncertain and transcript-empty
classifications are blocked. A proposal begins pending and inert. Admission requires an explicitly
authorized selected Primary and an exact current analysis key (Primary/occurrence/epoch,
source, model, transcript/correction, format/asset, alignment,
protection, output recipe and other-cut revisions), exact affected-lane revisions, one shared rounded
grid interval and output rate, and independently complete proof for **each** affected lane. An
inaccessible, unmapped or ambiguously invertible audio lane must be `unsupported`, not silent. A
silent lane must have a separately supported timed grid interval. Each audio lane needs current
backing, matching occurrence/channel/epoch, complete protection coverage, <=1 output-frame endpoint
error and the actual source-frame removal and **final merged** fade footprint. Intersections at the
last frame refuse Shorten and Lift alike; Lift is an equal-duration gap alternative, not a waiver.
No fade is enabled without an Alignment/renderer-verified final footprint and output-frame lengths.

`ReviewJournal` records named pending/adjusted/accepted/rejected/restored/abstained/blocked states;
Restore keeps the accepted cut's evidence and removes activity. Undo Restore and redo Accept require
fresh identical all-lane proof or leave the inactive state and history untouched. The app must
coordinate one common-map revision change and preview/render invalidation atomically on publication;
this pure target deliberately does neither. The current synthetic tests include 120 adversarial
protected-frame placements tested under both modes, plus absent/hallucinated timing, ambiguous
inverse, uncovered lane, last-frame merged fade, stale keys and identical undo/redo state.
They are a **bounded precursor**, not the frozen precision or real-material gates.
