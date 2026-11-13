# Automatic alignment

`AlignmentPipeline.analyzeSpeaker` produces a reviewable acoustic proposal,
not a recorder-clock approval or proof of continuous sample correspondence.
Acceptance is explicit, undoable `manual(.acceptedAcousticProposal)` timing
for the target recorder group, followed by verified save and current activation.

## Versions and authority

The selected-speaker affine candidate is `ww-auto-align/4`; its analysis asset
and `EpochAnalysisRecord` versions are 4. Fingerprints use
`ww-spectral-fingerprint/1`. Adaptive evidence uses `ww-adaptive-align/14`.
These recipes identify inputs/methods, not quality certification.

`WWAutoAlign` consumes decoded buffers with native Accelerate double-precision
DFTs. It has no source opener, model/network or approval API.
General multi-recorder/cycle analysis still uses the separate `WWAlignEstimate`.
Maintained trees are **not** necessarily byte-identical to their historical
freezes: [test support](../../test-support/README.md) distinguishes `currentTrees`
maintenance pins from immutable records, seeds and holdout gates.
Development fixtures/calibration are not unseen qualification.

Every result binds source/format/channel/placement revisions, reference-map
content, recipe and supersession state. Old payload versions refuse rather
than receiving new semantics. Accepted maps retain independent dependencies;
an estimator update does not revise them.

## Whole-track discovery and precise affine evidence

1. Stream each selected whole channel through the authorized gateway, with
   cancellation/source checks. Build six log spectral bands (100-1800 Hz) plus
   RMS in 40 ms frames on a 20 ms grid. Remove common energy from spectral
   shape so shared pauses/loudness alone cannot establish identity.
2. Select content-rich four-second target passages and search the **whole**
   reference using a 10 Hz aggregate/cached spectra. Coarse agreement seeds
   discovery only; no initial anchor or +/-120-second placement hint is required.
3. Refine safe overlap in up to 16 disjoint temporal regions, with up to three
   content-selected passages per region. Obtain fresh two-second waveform
   NCC/independent GCC-PHAT evidence in bounded searches. A forward/backward
   150 Hz speech high-pass at 4 kHz reduces rumble without net phase shift.
   A bounded coarse-rate hint affects analysis only, not recordings or clocks.
4. Fit deterministically with bounded hypotheses/weighted refinement. Preserve
   all attempts, failures, delays and polarity checks. One region supplies at
   most one temporal coverage vote; overlapping windows are not independence.

NCC is the reported fine measurement; PHAT is an independent corroborating
veto, not an opportunistic replacement when NCC fails. Absolute peaks allow
opposite recording polarity, but the methods must agree on polarity.
Fine delays retain their actual source-coordinate centers after resampling.

| Stage | Gate |
| --- | --- |
| Coarse | Peak >=0.25, competitor outside 300 ms <0.8 of winner; >=3 discovery regions, >=80% consensus within 150 ms |
| Fine | NCC >=0.35; competitor outside 5 ms <0.8; PHAT uniqueness; delay agreement <=1 ms, polarity agreement; reject edge peaks |
| Fit | >=5 regions, >=60% planned stations, >=80% overlap span and usable consensus; residual <=1 ms; rate within +/-500 ppm |
| Coverage | Two consecutive unmeasured/unusable regions refuse insufficient coverage, not an invented physical restart |
| Contradiction | Consecutive contradictory regions or consistent stepped runs refuse; do not discard an entire contradictory region as isolated outliers |

Shared silence needs both full energy profiles or fresh shared-silence evidence;
it supplies no precise timing vote. Asymmetric silence/coverage remains explicit.
The fitted relation is reference time = rate * target time + offset, rounded
to 1 ppb/1 ns in the exact map. Good acoustic fit and human acceptance cannot
separate propagation delay from a physical recorder-clock difference.

## Bounds, caching and channels

Reject channels longer than two hours before decode. Indexing streams once;
fine batches seek where supported or stream bounded windows otherwise.
Shared admission defaults to two permits/512 MiB estimated working set, maximum
four configured permits. Reserve retained indexes, FFT/resampling scratch,
decoded channels and result metadata together. Never nest admission while
holding a permit or launch unbounded per-core work.

Cancellation is checked in gateway reads/seeks, resampling, feature frames and
observations. Cached fingerprints remain source/channel/format/recipe-specific
and still require live authorization. Inconclusive evidence never becomes a
physical gap merely because decoding succeeded.

Unknown channel resolves automatically only for freshly verified mono.
Preserve/check explicit choices; stereo/multichannel never defaults to zero.
Metadata menus may use observed counts, but analysis rechecks both participants
with current authorized probes without silently rewriting saved assignments.

## Adaptive evidence

Adaptive fallback applies to inconsistent/discontinuous affine evidence, not
missing access, weak identity, malformed inputs or arbitrary failure.
It preserves the selected file/reference direction; it does not infer a better
device hierarchy or use newly proposed relay timing as accepted authority.

Read four-second batches on a three-second stride, at most twelve in memory.
Fresh adaptive full-window NCC must be >=0.6 with ordinary uniqueness, method,
polarity and 1 ms checks. Bounded predetermined corroboration paths use genuinely
disjoint subwindows; a complete grid passes by itself. Do not pool favorable
windows from overlapping grids or search arbitrary lengths until something fits.

Current paths include disjoint half-/0.66-second grids, a strictly corroborated
canonical half-second sequence support, one fixed upper-band spectral fallback,
and a fixed centered one-second proof with three disjoint quarter-second checks.
Actual interval durations determine independence. Broad spectral witnesses and
overlapping contexts can veto, but cannot add independent votes.
Strong unique contradictions remain vetoes even if another grid passes.
Missing/invalid witnesses never establish quiet or sufficient support.

Each independently measured local line needs at least three disjoint supports,
all points within 1 ms and +/-500 ppm, with no inconvenient point trimmed.
Use feasible bounded fitting rather than rejecting solely because unconstrained
least squares chooses an invalid rate/intercept. Unusable/contradictory windows,
unsupported spacing or a failed line split the run. Only supported centers
bound coverage; contexts and unmeasured ends cannot extend it.

Provenance is explicit:

| Kind | Evidence and limit |
| --- | --- |
| Measured | Independently corroborated waveform supports; conservative local rate/offset, not physical-clock proof |
| `quietTransition` | Guarded energy-only interior between independent runs; no new timing votes or VAD claim |
| `anchorGuided` | Fresh short-passage waveform matches in a bounded independently anchored corridor; not an independent clock model |
| `estimated` | Interpolated/extrapolated safe playback where the other evidence is absent; not recovered speech |

Quiet transitions require neighboring support, source gap 0.5-60 seconds,
endpoint delay change <=50 ms and connecting rate within 1%. A bounded second
pass measures raw full-band 100 ms RMS/peak bins: maximum across all target
channels, selected reference channel. Both sides' candidate interiors plus
200 ms guards must pass local-floor/neighbor-relative thresholds for >=300 ms.
One-sided dropouts, loud transients or activity on another target channel remain
unknown. Energy thresholds cannot prove absence of faint speech/music.

Anchor-guided recovery uses gaps <=5 minutes with endpoint delay change <=50 ms,
at most four 12-second slices per batch. A fixed five-state feature path within
40 ms of endpoint interpolation guides fresh searches only. Every 300 ms,
half-/canonical-quarter waveform NCC/PHAT must agree within 1 ms, be unique and
non-edge, and meet NCC >=0.65/>=0.75 respectively. Failed/quiet/contradictory
windows split support. Actual checked quarters alone set bounds; their lines
remain within 1%, monotone and separately labeled, without replacing measured
or quiet regions. Reserve the combined profile/slice/witness metadata budget.

## Acceptance, playback and downstream work

Recheck cached-result equality and both live participants, then project through
the **final accepted reference**. A changed root uses its original clock.
Other recorder mappings/provenance survive only where their groups remain
unchanged. Unrelated file corrections survive manual edits only with unchanged
corrected/reference groups and inclusion in the new dependency digest.
An invalidating change refuses instead of silently deleting them.

The app's individual and batch adaptive acceptance **preserves full source
audio by default**, using estimated gap/end timing. Confirmed geometry is retained
where safe. Estimated ramps may widen into adjacent support only as necessary;
replaced support is relabeled estimated. The complete curve must remain
monotone, nonoverlapping, bounded and within native rate 0.98-1.02.
If safe full coverage is impossible, refuse rather than mute unmatched audio.
Cached measured-support counts do not increase when estimates fill playback.
Explicit evidence-only callers and old regression fixtures can still request
measured-only behavior.

`Restore unmatched audio...` records a new undoable verified revision for an
old partial correction without reanalysis. Correction versions distinguish
measured-only (1), quiet transitions (2), and anchor-guided/estimated (3);
unknown kinds/versions refuse. Geometry and kind participate in canonical
identity. Measured/quiet/anchor-guided/estimated durations and markers stay
distinct, including accessibility labels and acceptance confirmation.

Native adaptive rendering uses recipe 5, bounded region-anchored multichannel
TimePitch and five-second cache tiles. Version-3 contiguous boundaries use an
8 ms linear overlap crossfade, half-width capped by half each neighboring
duration with identical weights across channels. Legacy unsupported boundaries
retain their four-millisecond fade/silence; old version rendering is unchanged.
See [audio processing](audio-processing.md) for runtime bounds.

Verified-save/activation ordering can be idempotent only for the latest issued
result's **full** alignment snapshot. Different restored content invalidates
pending tokens. Activation failure after a saved edit must say what saved and
what failed, not claim timing stayed unchanged.

Replacement alignment and Reset Alignment retire active transcripts, linked
reviews/cuts and working IN/OUT together in one Undo step, preserving originals,
assignments, raw histories and unrelated preferences. Reset is metadata-only,
works with unavailable/stale sources, and does not run analysis. Verified save
still gates runtime activation, including Redo and other windows.
Cancel/failure/concurrent edits leave previous active work intact.
