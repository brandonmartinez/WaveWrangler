# Bounded automatic speaker alignment

`AlignmentPipeline.analyzeSpeaker` uses the native **`ww-auto-align/4` acoustic candidate**.
It proposes an offset and relative rate for review; it does not apply timing, prove continuity between
every sample, or approve a recorder clock. Acceptance is still an explicit, undoable
`manual(.acceptedAcousticProposal)` decision for the target recorder group, not just one speaker channel.

After verified save, a waveform refresh may restore the exact accepted map before the acceptance
completion callback runs. That ordering is idempotent only for the latest issued result's full alignment
snapshot; a different restored snapshot still invalidates pending acceptance tokens. Source, format,
placement, map-content, and supersession checks remain required. Acceptance failures expose named
descriptions and recovery steps instead of opaque NSError codes; a saved alignment is not described as
unchanged merely because its activation failed.

## Reset Alignment

**Reset Alignment…** sits immediately after **Align Tracks**. It is available only when the episode
has accepted timing and no alignment or transcription operation or recorder move is in progress.
Confirmation returns every recorder group, including locked groups, to its original source clock:
zero offset, normal speed, and no active automatic timing, manual adjustments, anchors, or adaptive
file corrections. No replacement analysis runs automatically.

Like accepting replacement alignment, reset retires active transcription and transcript-linked
reviews and cuts, and clears episode IN/OUT. The entire change is one **Reset Alignment** Undo step.
Original recordings, grouping, assignments, reference preference, listening choices, position-lock
preferences, and append-only timing and transcript history remain intact. Historical corrections and
user judgments are not active on the reset timeline; new accepted revisions cannot reactivate old cuts.
Analysis previews and pending reviews are discarded. Source-derived fingerprints and waveform samples
may remain cached, but cannot apply timing without a new explicit analysis and acceptance.

Reset is metadata-only and also works when the old timing is stale or a recording is unavailable.
The reset timeline, its runtime identity, and subsequent analysis remain gated on independently
verified save, including Redo and other windows sharing the show. Cancel or a concurrent show edit
leaves the prior timing and downstream work unchanged.

## Version and authority boundaries

The original `WWAlignEstimate` source and test trees remain byte-identical to
`m2-freeze-estimator-2`. General multi-recorder analysis and its cycle checks still use that estimator.
The new `WWAutoAlign` target is separate, consumes decoded buffers only, and uses Accelerate's native
double-precision complex DFT. It contains no source opener, decoder, network, model, or approval API.
No external implementation was copied or added as a runtime dependency.

The new candidate is **not a frozen holdout qualification**. Its deterministic fixtures are development
regressions/calibration, not a reuse or rerun of an old holdout. Future qualification needs its own
prospectively committed freeze, independently disjoint cases and complete reported results.
Neither a good acoustic fit nor human acceptance can distinguish microphone propagation delay from a
recorder-clock difference.

Analysis asset revision and `EpochAnalysisRecord` version are **4**. The recipe explicitly names
`ww-auto-align/4`, fingerprint/search/window/fit design, source revisions, selected channels and accepted
reference-map identity. Old analysis payloads are refused rather than interpreted as new results.
Previously accepted maps retain their existing independent dependency/currency checks and manual
authority; a cache/estimator update does not silently revise accepted timing.
The unchanged `ww-spectral-fingerprint/1` cache remains reusable; this revision changes precise
matching, not the whole-channel fingerprint format.

## Whole-track fingerprints, then fresh precise evidence

1. Stream **each entire selected speaker channel** once through the authorized WWDecode gateway.
   The existing anti-alias decimator now supports draining completed samples while preserving its
   history and exact sample coordinates; it does not allocate a recording-sized waveform.
   Build six log spectral-power features (100-1800 Hz), plus RMS energy, in 40 ms frames on a
   20 ms grid. Frame energy is removed from the spectral shape so shared pause/loudness envelopes
   alone are not speech identity. Each channel's binary `ww-spectral-fingerprint/1` index is cached
   through the derived coordinator, keyed by source revision, channel, format and decimator recipe.
   At 75 minutes, the seven float32 values use approximately **6.3 MB per channel**, plus a 16-byte
   header. Source changes invalidate the index; an unchanged channel is not decoded again for indexing.
2. Rank content-rich four-second passages throughout the full target and correlate their features
   against **the entire reference**, using a 10 Hz aggregate and reusable reference FFT spectra.
   Three independent unique matches may seed discovery, but are not an acceptable timing map.
   Coarse consensus uses a 150 ms tolerance, allowing feature-grid uncertainty and drift.
   This search does not depend on an initial anchor, timeline placement or a +/-120-second hint.
3. Derive safe overlap with the existing 500 ppm edge allowance. Divide it into up to 16 disjoint
   temporal regions, selecting up to three non-overlapping, content-rich passages within each region,
   rather than only trying predetermined sample times. Recheck features within 500 ms of the coarse
   line so repeated pauses do not redirect refinement to a distant unrelated passage.
   Each selected passage gets three fresh two-second waveform measurements in a +/-350 ms search.
   Fine analysis suppresses rumble with a 150 Hz second-order Butterworth high-pass run forward and
   backward at 4 kHz, avoiding a net phase shift; the existing anti-alias low-pass remains about 1800 Hz.
   A coarse slope within +/-500 ppm supplies an **analysis-only** rate hint. A 12-sample-radius
   Hann-windowed sinc resamples the target snippet onto the reference clock before correlation;
   a coarse slope outside that bound leaves local analysis at nominal rate. This does not modify
   either recording or accept the coarse clock estimate.
   Native waveform NCC provides the precise delay; GCC-PHAT independently checks its location and
   uniqueness. Both use absolute peaks to tolerate opposite polarity, but must agree on the sign as
   well as the delay. PHAT masks negligible energy in either spectrum rather than whitening noise-only
   frequency bins. Silence classification still uses the unfiltered buffers, so suppressing hum does
   not manufacture shared silence. These are new measurements:
   old weak, periodic or ambiguous observations are not promoted on the strength of similar lags.
   Keep one usable observation per temporal region; multiple passages in the same region do not
   count as independent temporal coverage. Persist all attempts, including failures, and both methods'
   delays. A region with shared silence can be recognized from the full energy indexes only when
   both channels are quiet throughout it, including a conservative reference search margin.
   Each delay is recorded at the actual target-source center (`start + 1 / rateRatio` for a two-second
   reference-clock template), not the resampled template's nominal center. This keeps the final
   offset/rate fit in original source coordinates.
4. Fit an affine delay line deterministically with at most 120 two-point hypotheses, then refine
   using correlation-quality weights. A limited number of **isolated** outliers may be excluded.
   Two consecutive contradictory measured regions, two consistent stepped runs, or less than 80%
   consensus among usable observations refuse the map. An entire contradictory region is never
   silently discarded as outliers. Consecutive contradictory precise regions also refuse when a
   different passage in those same regions happened to agree with the winning line.

The relation remains `referenceTime = a * targetTime + b`; reported rate is `1e6 * (a - 1)` ppm.
Final exact-map rounding is 1 ppb for rate and 1 ns for offset. When matching through an already
accepted reference recorder, the existing exact-map projection preserves the original timeline
reference and all other recorder groups.

### Gates and bounds

| Stage | Recorded rule |
| --- | --- |
| Coarse | Whole-reference four-second feature correlation; peak at least 0.25; second peak outside 300 ms below 0.8 of the best; at least three discovery regions, 80% consensus within 150 ms. Coarse evidence alone cannot produce a map. |
| Fine | Absolute NCC peak at least 0.35; second peak outside 5 ms below 0.8 of the best; absolute GCC-PHAT second/best below 0.8; methods agree within 1 ms and on polarity; edge peaks refused. |
| Fit | Inlier residual at most 1 ms; at least five regions, 60% of planned stations and 80% overlap span; at least 80% consensus among usable observations; absolute rate at most 500 ppm. Existing provisional 5 ms p95 / 10 ms maximum gates are not relaxed. |
| Coverage | Two consecutive unmeasured/non-usable regions refuse as **insufficient coverage**, not a physical restart. Shared silence needs quiet energy evidence in both full indexes or a fresh shared-silence window. |
| Decode | Maximum two hours per channel, refused before decoding when exceeded. First use reads each complete source once for indexing; fine batches seek when supported or stream once otherwise. Every cursor retains cancellation, source checks and final unchanged-source verification. |
| Memory | Existing shared `ResourceGate`: default two permits, 512 MiB aggregate estimated working set, maximum four configured permits. A single admission includes 160 MiB for indexes, binary cache payloads and coarse FFT scratch, plus all retained fine buffers, resampling/FFT scratch and multichannel decode chunks. No nested admission while holding a permit. |
| Cancellation | Checked during resampling, feature frames, every local observation/station and every gateway read/seek. No estimator tasks, unbounded task groups or per-core worker discovery. |

Inconclusive acoustic evidence never establishes a physical gap. The legacy pipeline also preserves
an existing primary abstention instead of overwriting it merely because consecutive windows were
ineligible. A provisional legacy result with unmeasured non-silent windows is refused for insufficient
coverage; asymmetric recorded silence remains explicitly unsupported.

## Synthetic evidence and choice of fine method

`WWAutoAlignTests` generates deterministic syllabic voiced/unvoiced material with changing pitch,
band-limited hashed excitation, pauses, gain, short FIR EQ, compression and independent noise.
Fine-method calibration generates only the needed windows at their true positions. Fingerprint
regressions additionally stream complete synthetic tracks, including a 75-minute gateway case.
Truth uses an independent prescribed affine relation, not residual against the fitted line.

Earlier v2 fine-method calibration on 2026-10-15 (Debug, Apple Silicon), not whole-track v3 qualification:

| Case | Independent-truth result |
| --- | --- |
| -38.617 s offset, +145 ppm, processed target, 8 kHz / 11.025 kHz, stations from 100 to 4400 s | Maximum map error 0.059 ms; estimated +145.00694 ppm; 16/16 usable regions. |
| +47.25 s offset, -180 ppm, same processing/rates/span | Maximum map error 0.072 ms; estimated -179.99335 ppm; 16/16 usable regions. |
| Quarter-gain target, unprocessed or EQ/compressed, noise amplitude 0.002 or 0.04, 8 kHz / 16 kHz | NCC worst error 0.0465-0.0498 ms; GCC-PHAT worst error 0.0314-0.0393 ms; all three attempts usable in each of four cases. |

NCC remains the reported fine measurement because it supplies a directly interpretable normalized
match coefficient and worked within the timing gate. PHAT is an **independent corroborating veto**,
not an assumption that whitening always improves microphone matching. PHAT had smaller errors in
this small synthetic comparison; it does not establish superiority on reverberant rooms, arbitrary
microphones or all noise distributions. Disagreement causes abstention rather than opportunistically
choosing whichever estimator produces an acceptable answer.

Regressions also cover unrelated and periodic audio, equally repeated solutions, actual offset steps,
asymmetric missing coverage, shared recorded pauses, isolated versus sustained outliers, unsupported
ends, cancellation and source changes before publication/during sparse decoding. A separate
classification-shape test uses 8 eligible / 3 periodic / 4 weak / 1 ambiguous observations with a
3 ms lag spread near -38.617 s; it asserts refusal without inventing a discontinuity. Those constructed
classifications are not accepted as new timing evidence. No real-media content or identifying
recording paths are included in fixtures.

Whole-track regressions cover sparse processed speech between the old fixed sample locations, both
offset signs, drift, chunk-boundary invariance at 8/11.025/16 kHz, binary round trips, cache reuse and
channel/revision separation, changed sources during indexing, cancellation, admission refusal and
the two-hour duration envelope. A seven-channel 44.1/48 kHz gateway case verifies a selected
non-first channel, and a -180-second offset case verifies discovery outside the old +/-120-second
hint without anchors. A long shared pause can be supported by both complete energy indexes without
counting silence as a precise timing measurement. They preserve the same fine timing and
false-positive assertions.

Initial v3 development measurements (Debug, Apple Silicon; synthetic, not real-media qualification):

| Case | Independent-truth result |
| --- | --- |
| Sparse processed speech, -18.617 s / +145 ppm, 180 seconds | Maximum map error 0.082 ms; 23 content-selected passages refined. |
| Sparse processed speech, +21.25 s / -180 ppm, 180 seconds | Maximum map error 0.135 ms; 21 content-selected passages refined. |
| 75-minute, mono 8 kHz gateway case, -38.617 s / +145 ppm | Maximum map error 0.00127 ms; +145.00032 ppm; 75,920,159 decoded frames including both complete indexes and sparse refinement; admission peak 204,005,376 bytes, sampled resident about 116 MB and footprint about 70 MB. These are process observations, not universal guarantees. |

V4 processing/drift development regressions (Debug, Apple Silicon; synthetic, not real-media qualification):

| Case | Result |
| --- | --- |
| Processed speech with EQ, compression, low gain, independent 60/90 Hz rumble and +480 ppm, tested with each polarity | Previous matcher supplied 0/3 usable windows in each case; speech filtering, polarity checks and analysis-rate compensation supplied 3/3, each within 1 ms of independent truth. |
| Local speech windows with -480 ppm and +480 ppm | Median NCC improved from 0.6021 to 0.9967 and from 0.6780 to 0.9966 respectively; all three windows usable, with source-coordinate error below 0.25 ms. |
| Complete 96-second gateway recordings with processing, hum, +180 ppm and each polarity | Both returned a reviewable proposal within 1 ms of independent truth, with the correct polarity evidence and no automatic acceptance. |

Unrelated processed speech, periodic tones and equal echoes still refuse. Rate compensation does not
relax coverage, competing-peak, method-agreement, consensus, residual or discontinuity gates.
The final result is still one measured constant rate plus offset, not elastic peak-by-peak warping.
Accepted playback remains rate correction, not pitch-preserving time stretching.

### Double-precision CPU reuse (2026-10-18)

The reached `WWAutoAlign` fine path now shares **both input spectra and the existing forward/inverse
Accelerate plans** between ordinary correlation and energy-masked PHAT. A three-attempt
`AutomaticAlignment.measure` call caches at most one plan pair, reusing it only when the next
attempt needs the same power-of-two padding size. Clipped source boundaries can reduce that size;
they do not inherit a larger transform and different rounding. Plans and spectra are computation-local,
not global mutable state or a recording-length cache. `AnchoredTiming.measure` uses the same paired
correlation helper. Existing single-correlation and precomputed-reference-spectrum entry points remain
compatible for coarse matching and adaptive corroborations; `AdaptiveMeasurement.swift` is unchanged.

The same 24-tap, radius-12 normalized Hann-windowed sinc uses
`sin(pi * (fraction - integer)) = (-1)^integer * sin(pi * fraction)` and the cosine subtraction
identity. Immutable tap sine/cosine constants replace per-tap transcendental evaluations with three
evaluations per output sample. Tap order, clipping, normalization, integer-rate slice fast path,
Double coordinates and cancellation checks are unchanged. There is no Float conversion, Metal/ANE
backend, dependency, public selector, recipe/schema change or threshold adjustment. The unrelated
frozen `WWAlignEstimate` FFT remains untouched.

**Production release before/after**, Apple M5 Max (Mac17,14, 18 CPU cores, 128 GiB),
macOS 27.0.1, Xcode 27.0 / Swift 6.4. Baseline source is committed local
`5e163137a98dd8304e3f4c7f967bd9fb801131ae`, a descendant of research baseline `370d41f1`;
committed sentence/transcription work is preserved. Three serial repeats, `-O -enable-testing -DDEBUG`,
three build jobs, one test worker, no app build/launch or shared build paths.

| Generated real WAVE pair | Reference / target rate; selected lane | Offset / drift | Warm baseline ms, median [min,max] | Warm optimized ms, median [min,max] | Reduction |
| --- | --- | --- | --- | --- | --- |
| 64 s mono | 48/48 kHz; 0 | +0.83 s / +180 ppm | 137.985 [133.896,139.562] | 89.718 [89.600,91.377] | 35.0% |
| 600 s stereo | 48/48 kHz; 1 | -1.25 s / -145 ppm | 486.741 [485.554,510.270] | 331.931 [330.358,335.611] | 31.8% |
| 1800 s mono | 8/8 kHz; 0 | +2.25 s / +180 ppm | 594.732 [594.610,604.328] | 439.052 [439.018,449.058] | 26.2% |
| 96 s seven-channel | 44.1/48 kHz; 6 | +0.83 s / +180 ppm | 173.985 [172.624,174.070] | 126.895 [126.872,128.521] | 27.1% |
| 64 s inverted mono | 48/48 kHz; 0 | -0.83 s / -180 ppm | 136.367 [136.048,138.096] | 89.748 [89.638,92.556] | 34.2% |

These are actual `AutomaticAnalysis.run` warm rematches: admission, fingerprint cache reads, fresh
coarse search, revision-checked sparse system decoding/decimation, all fine attempts, fit and record
encoding/decoding. They are **not kernel-only or experimental estimator replays**. The opt-in harness
first asserts full record equality against `analyzeSpeaker`, and separately measures its final-record
cache (about 1-3 ms); outer coordinator publication/UI latency is excluded from rematch timing.
Each WAVE uses deterministic seed-990, 2 kHz interpolated scene data on an 8 kHz base grid;
target gain is 0.7 and other channels are unrelated noise. This reuses development controls from the
local CPU study, not independent recorder ground truth or held-out speech qualification.

This was a **shared-machine, fixed-order before/after measurement**, not exclusive-machine timing
or an energy claim. Load averages were approximately 6-9; security scanning, WindowServer and another
speech experiment were active. Thermal state stayed nominal. Digital silence, periodic tone,
very-low-level unrelated audio and normal-level unrelated audio still abstained. Their 1-4 ms warm
times are dominated by cache/scheduling noise (the low-level median rose from 1.11 to 1.98 ms);
they do not reach the optimized fine path, so no negative-control speedup is claimed.
Dense adaptive/quiet/anchor recovery has behavioral coverage, not a separate end-to-end speed claim.
The combined improvement is measured; these numbers do not isolate the contribution of each edit.

For all 27 before/after records the harness checks identical input SHA-256s, source rates/frame
ranges, coarse evidence, coverage, methods, polarity, classifications, abstention and rounded affine
rate/offset. Reported NCC/PHAT lag deltas were zero; maximum NCC score delta was `4.44e-16`.
Positive-control endpoint truth error stayed below **0.00260 ms**. `RecordingDSPTests` additionally
compares the full Double correlation arrays **bit for bit** with frozen pre-optimization arithmetic
at 8192/32768/131072 points, including both mask directions, tiny cross-power and reused/reversed inputs.
Its sinc sweep covers clipped ends, unit/near-unit rates, +/-500 ppm and source indices through
159999: maximum absolute sample difference **6.66e-16**, worst per-case RMS **8.31e-17**;
unit-rate output is exact. Fine-path replays include both offset/drift signs, polarity, upper speech,
one-/two-second windows and a 32768-to-16384 padding change within one call.
Existing reliability cases retain silence/periodicity/unrelated/step refusal, cancellation,
selected-channel/source-frame mapping, changed-source publication vetoes and manual acceptance.
Release validation passed 70 `WWAutoAlign` and 72 related pipeline regression tests, plus the
opt-in benchmark. The existing 75-minute control still decoded 75,920,159 frames with a
204,005,376-byte admission peak and maximum independent-truth map error below 0.004 ms.

The narrow opt-in harness is `WWAlignPipelineTests/RecordingAlignmentBenchmarkTests.swift`.
Raw evidence is worktree-local and ignored: `.build/recording-cpu/{baseline,optimized}/`
contains `timings.json`, full record snapshots, hashes, media and caches; sibling logs,
`environment.txt`, contention snapshots and `summary.json` retain the measurement context.
To rerun, use a **new** absolute output path and a non-symlinked local scratch directory:

```bash
source "$HOME/.shell/exports-core.sh"
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
WW_RECORDING_BENCH_DIR="$PWD/.build/recording-cpu/new-run" \
WW_RECORDING_BASELINE="$PWD/.build/recording-cpu/baseline" \
swift test --package-path Packages/WaveWranglerKit \
  --scratch-path "$PWD/.build/recording-cpu/swiftpm" --configuration release \
  -Xswiftc -enable-testing -Xswiftc -DDEBUG --jobs 3 --no-parallel \
  --filter 'WWAlignPipelineTests.RecordingAlignmentBenchmarkTests'
```

Omit `WW_RECORDING_BASELINE` for a standalone run or to capture the first run with the unchanged
harness against baseline production source before applying the DSP edits. Comparing two runs
requires matching workloads/repeat counts. Optional `WW_RECORDING_CASES=scene-64,stereo-600` and
`WW_RECORDING_REPEATS=1` bound the matrix (default three, maximum five). No external media or downloads.
Normal numerical/safety coverage uses the same release flags with `WW_ESTIMATOR_TESTS=1` and filter
`WWAutoAlignTests`; related pipeline tests use the `AutomaticAnalysisTests`, `AutomaticPipelineReliabilityTests`, `AdaptiveAnalysisTests`,
`AdaptiveAcceptanceTests`, `AcceptanceTests`, `ConcurrencyTests`, `GuardTests` and
`WitnessBoundPCMWindowTests` suites. No shared test-support, sentence/transcription or project files change.

The app's review surface reports full indexed durations, source interval, usable/agreeing regions, attempted windows and their
local classifications, excluded isolated outliers, fit residual and the distinction between sampled support and continuous
inspection. It also labels the coarse rate hint as analysis-only, not accepted timing, and reports
opposite-polarity matches without claiming the recordings were inverted. Coarse failure retains its
reason; no success-shaped map is returned.

## Source-local adaptive alignment

`AlignmentPipeline.analyzeAdaptiveSpeaker` adds a separately versioned **`ww-adaptive-align/14`**
path. It does not change the affine estimator, frozen time-map/render contracts, or
`EpochMapDecision`. A software/network recording can share strong speech matches
while its delay changes locally; that is not automatically recorder drift or a physical restart.

The normal global **Align Tracks** workflow now invokes this existing adaptive path automatically
when a channel-specific affine result abstains as `inconsistent` or `discontinuous`. Individual
**Align…** does the same and opens the existing adaptive preview. Successful affine fits, missing
assignments, unresolved multichannel choices, weak/ambiguous evidence, and access failures do not trigger this
fallback. Global analysis reuses its captured affine seed instead of repeating that analysis.
No DSP threshold, estimator version, or stored evidence is promoted or relaxed.

Channel-specific matching resolves an unknown channel only when fresh decoded source facts verify
that the file is mono. Explicit choices are preserved and checked against the decoded channel count;
stereo/multichannel recordings never default to channel zero. Metadata-only menus may use previously
observed counts or already loaded waveform headers, but analysis rechecks both participants against
its current authorized probes. This resolution neither rewrites saved assignments nor migrates legacy
unknowns. Affine and adaptive paths share the same resolution helper. Missing choices are typed setup
requirements naming the recording and channel count, not internal encoding failures.

The global review exposes supported file timing separately from recorder timing. Estimated gaps
remain a second, off-by-default choice; acceptance requires an additional warning. Selected affine
and adaptive decisions publish in one verified-save/Undo transaction. Adaptive acceptance uses the
shared cached-evidence and original-source checks, requires current authorization for both measured
participants, and recomputes projection through the final accepted reference placement. When the
selected root changes, analysis uses its original clock rather than its former accepted offset.
With an unchanged root, unselected current recorder mappings and their proposal provenance survive
replacement review. Existing unselected file corrections also survive only when their recorder and
reference groups remain unchanged; an invalidating change refuses instead of silently deleting them.

This integration preserves the selected timeline reference, not an inferred device-quality hierarchy:
the chosen speaker pair still determines which file receives the curve. It does not automatically
reverse a local-recorder-to-Teams comparison to repair Teams instead. References on other recorders
must already be timed; newly proposed relay timing is not used as an unaccepted analysis authority.
The historical real-pair measurements below are not new qualification of this workflow.

The candidate reuses the current channel-specific fingerprints and coarse overlap/search seeds.
It reads four-second target batches on a three-second stride, at most twelve batches in memory,
using `AutomaticAnalysis.buffers` and the same gateway, source-revision checks and shared admission.
Three overlapping two-second NCC/PHAT measurements per batch give approximately one observation
per source second. Ordinary v4 fine filtering, rate compensation, uniqueness and NCC/PHAT
method/polarity checks remain unchanged. An extra adaptive NCC gate requires at least 0.6.
Fresh adaptive measurements can additionally corroborate a full-window NCC/PHAT lag agreement
using three disjoint half-second signed NCC windows, spaced 0.75 seconds apart. Each must have
score >=0.55, a competing peak below 0.8 times the winner, the same NCC polarity, and a delay
within 1 ms of the full-window delay. If that grid is inconclusive and contains no strong
contradiction, one predetermined alternative uses starts at 0.125, 0.75 and 1.375 seconds instead
of 0, 0.75 and 1.5 seconds. A complete grid must pass all three checks by itself; individually
good windows from different, overlapping grids never pool to manufacture independence.
If both half-second grids remain inconclusive, a final fixed grid measures three longer
0.66-second windows starting at 0, 0.67 and 1.34 seconds. It supplies more distinctive speech
context without relaxing score, uniqueness, polarity or delay gates. Actual window lengths
are recorded and used in the non-overlap calculation; longer windows cannot masquerade as
half-second independent supports. All attempts remain recorded in grid order, including
ambiguous/weak checks. A strong unique contradiction from any attempted grid vetoes support
even if another grid passes. There is no open-ended position/length search.
This is fresh, separately versioned adaptive evidence, not retroactive promotion of a failed
affine result. Inconclusive subwindows alone do not erase otherwise valid fresh affine evidence.

V6 additionally permits one canonical middle half-second to supply **one**, not three, sequence
supports when the complete grids remain inconclusive. It must independently pass the same score,
uniqueness, polarity and delay checks, with unique full-window NCC/PHAT peaks and agreeing full
lags. The middle is fixed in the original grid; another grid's better-scoring window cannot replace
it. All attempted context checks must also score at least 0.55 and agree on polarity and delay,
even when their competing peaks are ambiguous. Weak context is not assumed to be silence, and
ambiguous-but-disagreeing context vetoes this tier in addition to the existing strong-unique veto.
Three such supports require three actually disjoint measured windows across observations.
Their overlapping full-window contexts never count as additional independent confirmations.
No pooled or averaged lag profile manufactures eligibility.

V7 adds a distinct low-energy-context method. Fresh measurements retain centered speech-band RMS
and peak amplitude for both sources at the **full-window relationship**, not at whichever noisy
local peak wins. A weak or ambiguous context check may be treated as shared quiet only when
both RMS values are below the existing 0.0001 silence cutoff, at least 30 dB below their
respective canonical-middle RMS, and both peak amplitudes are at least 20 dB below their
respective middle peaks. Missing, nonfinite or invalid metadata never establishes quiet.
One-sided software dropouts and narrow loud transients therefore cannot use this exception.
Every strong unique contradiction still vetoes the observation, even at low energy. The middle
must remain independently sufficient, and quiet context supplies **zero** timing supports.
This is an energy guard, not ground-truth speech detection or proof that no edit occurred.
Complete-grid and strict-sequence quality gates remain unchanged.

V8 keeps a sufficient complete grid first, then uses a separately sufficient canonical half-second
before falling back to an ordinary two-second observation. Previously a valid ordinary observation
could hide that shorter measured support: three distinct short utterances still looked like
overlapping two-second measurements and supplied insufficient independence. A fresh synthetic
three-utterance control reproduces that loss. The shorter support uses its actual measured center,
delay and duration, never the full-window context as extra confirmations. Ordinary evidence remains
available whenever the stricter localized proof fails; the ordinary v4 estimator itself is unchanged.

V9 fixes local fitting rather than weakening measurement gates. Unconstrained least squares can
prefer a rate outside 500 ppm, or an intercept with a residual over 1 ms, even when another line
satisfies **every** measured point within both existing bounds. The adaptive fit incrementally
intersects the admissible slope intervals from every pair of points, then chooses a feasible
intercept. An already valid weighted fit is retained unchanged. All residuals are checked again;
no point is trimmed. Independence, invalid-window splits, unknown transitions and monotonicity
still apply. This is local bounded compatibility, not a claim of a physical recorder-clock rate.

V11 adds one fixed spectral fallback, not an open-ended search for a filter that happens to pass.
Previously sufficient broad-band observations remain unchanged. For a subwindow/method-inconsistent
observation, both decoded snippets are freshly measured with an additional forward/backward 600 Hz
high-pass after the existing 150 Hz speech filter. This is analysis only; the audible original is
not filtered. The upper-band observation needs a complete, genuinely disjoint corroboration grid,
with the existing score, competing-peak, signed-correlation and delay gates. Its full NCC and PHAT
peaks must additionally be unique and agree within 1 ms.

The original broad-band measurements are retained as a separate `SpectralTimingWitness`, not erased
or relabeled as eligible. Both broad full-window peaks must be unique, NCC must score at least 0.6,
and NCC/PHAT delays must agree with each other and the upper-band delay within 1 ms. The canonical
broad middle half-second must itself be unique, score at least 0.6 and agree on delay. Every strong,
unique broad contextual delay remains a veto when it disagrees. Missing or malformed witnesses
refuse this tier. The broad middle and overlapping spectral views supply no extra independence:
only the three actually disjoint upper-band windows count as supports.

Within each filtered band, opposite correlation signs still veto a grid. Signs are not compared
**between** different filtered bands: frequency-dependent processing can favor different signed
lobes less than a millisecond apart. A generated-PCM two-tap differentiator reproduces that case
without a source-clock step and recovers the known offset through the new path. This does not
identify the filtering used by the real conferencing recording. Cross-band delay agreement,
whole-grid proof and all existing local-fit, rate, gap and monotonicity gates remain mandatory.
Persisted window records retain both the upper-band checks and the broad witness; numeric replay
rechecks the same proof. Admission explicitly reserves space for the additional witness metadata.

V12 adds one fixed, freshly measured shorter-window fallback when the existing paths cannot supply
usable evidence, including ordinary observations whose eligible label still falls below the adaptive
0.6 score gate. It measures a centered one-second broad-band window at the existing observation
center. Full NCC and PHAT peaks must be unique, agree within 1 ms, and have NCC at least 0.6.
Three disjoint quarter-second NCC checks have fixed starts at 0, 0.375 and 0.75 seconds. Each must
score at least 0.6, have a competitor below 0.8 times its winner, and agree with the full window's
delay and NCC polarity. A separate canonical middle half-second must pass those same gates.
Only the three quarters count as independent supports; the overlapping half-second is additional
output evidence, not a fourth vote. All four checks and their real durations are retained.
The supported interval remains bounded by measured quarter-window centers, never by the larger
one- or two-second context. Existing sufficient observations are not replaced, and there is no
open-ended duration/grid search or relaxation of the 1 ms, 500 ppm or gap limits.

Mixed-length support counting now uses earliest finishing intervals rather than earliest centers.
A long earlier observation could otherwise hide three genuinely disjoint shorter observations.
The interval-selection order changes only the independence count: every observation still
participates in the bounded fit and can contradict it. No inconvenient point is removed.
When only the new short proof supplies sufficient independence, otherwise insufficient long
contexts cannot extend the supported interval to their unverified centers. They still constrain
the fit; bounds come from the locally corroborated centers. A generated shared-burst/otherwise-
unrelated control covers this distinction. Already independently sufficient long support remains
available unchanged.

V13 adds **quiet-only transitions**, separately from all measured speech regions and quality
counters. It never adds a silence fingerprint, timing vote, or a more lenient speech fit.
Only neighboring independently supported runs can bound a transition. Their endpoint relationships
define an affine connecting line; the source gap must be 0.5--60 seconds, the change in delay at
most 50 ms, and the connecting rate within 1% of nominal. This is bounded pause elasticity, not a
hardware-clock estimate. The fixed hardware/reference map remains unchanged.

A second bounded streaming pass measures **raw full-band, uncentered** PCM in source-anchored
100 ms bins. Target energy uses the maximum RMS and peak across **every channel**; it never uses a
downmix. The reference uses the selected speaker channel because that file is not edited. Sample
rates, frame continuity/counts, finite samples, source revision and final source currency are
checked. Profiles retain no whole-track PCM. Admission reserves an additional 48 MiB for bounded
profiles, transition witnesses and serialization.

For each side, the local background floor is the tenth-percentile RMS in a +/-10 second
neighborhood of the gap midpoint. The RMS ceiling is the minimum of 0.001, the larger of 0.0001
and twice that floor, and 30 dB below the weaker neighboring speech anchor. Peak must be below
both 0.003 and 20 dB below the weaker anchor peak. Anchor levels come from the measured
two seconds nearest each gap boundary, confined to the already measured region on the selected
channel. Measured window centers can lie just inside a pause; sampling only their nearest half-second
could mistake that quiet boundary for the speech anchor's level. The complete candidate interval
plus 200 ms guards must pass in **both** recordings. Candidates consist only of full source bins
strictly inside the gap, last at least 300 ms, and retain their target/reference energy witnesses.
No partial bin or guard outside a complete source profile is assumed quiet.

Only passing quiet interiors are added. An unknown gap may contain an unverified voiced tail,
quiet room tone, and an unverified next onset: the voice edges stay absent rather than inheriting
the connecting line. A transient, low-level burst above the local threshold, active other target
channel, or one-sided dropout leaves that portion unknown. Energy thresholds cannot semantically
distinguish arbitrarily faint speech/music from background noise: this is explicitly an energy
heuristic, not VAD, a guarantee of inaudibility, or extra measured-speech coverage. Review remains
required.

The result preserves measured regions and counters unchanged and stores optional
`quietTransitions` separately. Numeric replay rechecks the serialized witnesses, all-channel
count, guards, original neighboring anchors, duration, rate and delay bounds. Acceptance additionally
requires exact cached-result equality and live source/reference checks. Preview and accepted
markers label quiet-derived timing with orange waveform icons; measured/quiet counts and durations
remain separate. Other gaps and leading/trailing audio still have no inferred placement.

V14 adds **anchor-guided short-passage recovery**, without modifying any V13 independently
measured run, quiet transition, or original window counter. Neighboring independent runs bound
a search corridor: source gap at most five minutes and endpoint delay difference at most 50 ms.
Long gaps are read in at most four twelve-second slices per batch, with bounded filter context,
under the existing admission. A five-state dynamic-programming path compares the six existing
log bands in half-second contexts on the 20 ms feature grid. States sit at -40, -20, 0, 20 and
40 ms around endpoint interpolation; neighboring states can move by at most one step and incur
a movement penalty. This guides search only: neither features, interpolation nor overlapping
contexts supply acoustic timing votes. It is a bounded local feature path, not whole-recording
DTW or a claim to reconstruct conferencing edits.

Every 300 ms, fresh half- and canonical quarter-second **waveform** NCC and PHAT searches must
both pass. The half needs NCC at least 0.65, the canonical quarter at least 0.75, and each needs
competitor ratios below 0.8 outside the existing 5 ms
exclusion, matching within-band polarity, non-edge peaks and NCC/PHAT agreement within 1 ms.
Both durations must agree within 1 ms. Silence or any failed/contradictory observation splits
support. A single passing canonical quarter can be retained because surrounding independent
anchors already constrain the search, but is explicitly **anchor-guided**, not a newly established
three-support clock model. Bounds never extend outside those actually checked quarters.
Consecutive disjoint quarters can share a line only with all center residuals within 1 ms,
rate within 1%, consistent polarity and monotone source/reference geometry. They cannot overwrite
measured runs or quiet transitions. All fresh observations, including failures, and the full/quarter
NCC and PHAT witnesses are persisted; deterministic replay rebuilds the separate recovered geometry.
No old failed observation is promoted. Admission reserves 80 MiB for the combined quiet profiles,
recovery metadata, bounded slices and serialization (32 MiB above V13).

An explicit, **default-off** option keeps remaining bounded gaps using **estimated timing**.
It interpolates only between neighboring confirmed intervals, never before the first or after
the last. Each source gap is 10 ms to five minutes, endpoint delay change at most 50 ms and
projected rate within 1%. Estimates are constructed after clipping/projecting through the actual
accepted reference, preserving all confirmed geometry and avoiding floating-point overlap at joins.
The minimum gap prevents three join crossfades from overlapping. Estimates do not certify
missing audio, speech identity, continuity, recorder-clock accuracy or
millisecond alignment. Gaps that cannot meet those bounds remain silent even with the option on.
The option is an explicit acceptance argument, never an alteration of the cached analysis.

Green markers identify anchor-guided acoustic matches; purple question marks identify estimates.
Counts, duration, proposed ghost, accepted markers, accessibility labels and acceptance confirmation
retain that distinction. Filling estimated playback must never be reported as recovered speech.
Version-3 contiguous boundaries use an eight-millisecond linear overlap crossfade rather than
two fades to silence. Identical weights apply to every channel; unsupported boundaries retain
their existing four-millisecond fade and silence. Legacy version-1/2 rendering is unchanged.
The native render recipe is revision 3 so tiles and derived audio cannot reuse the older recipe.

Independent measured support remains deliberately conservative:

- Every accepted local line needs three non-overlapping measured supports. Ordinary v4 supports
  occupy two seconds; independently corroborated adaptive subwindows occupy 0.25, 0.5 or 0.66 seconds each.
  Overlap never inflates the independence count, including between neighboring full windows.
  Separation conservatively includes the longest source window at the permitted analysis-rate
  correction. Every fitted observation must agree within 1 ms and 500 ppm. This allows short,
  independently measured speech without requiring seven uninterrupted seconds of speech.
- An unusable/ambiguous/contradictory window, a measurement interval over 1.01 seconds, or a failed
  local line ends the run. The candidate does not trim inconvenient observations as outliers.
- Measured regions run only from the first to the last supported observation center. Unmeasured
  ends and active transitions remain absent, not filled with nominal timing or mislabeled as
  restarts. Only separately verified quiet interiors may use the bounded V13 connecting line.
- Source and projected reference intervals must remain monotone and non-overlapping. A curve that
  would replay/reverse reference audio refuses instead of silently discarding the contradiction.
- The existing two-hour/channel limit applies. Admission includes the same fingerprint/FFT reserve,
  retained PCM batches, scratch and multichannel decode chunks. Sequential-only gateways still use
  one forward stream **per batch** and can be substantially slower than seekable sources.

An adaptive derived asset has its own version/recipe and slot per target source, depends on the
current affine-analysis identity and selected channels, and keys the active map revision and **all**
accepted-map source dependencies when using an accepted reference. The UI also checks episode
sources, groups, speaker assignments, pair and accepted revision before publishing or displaying
the result. Reference-source seconds are projected through the reference's continuous accepted
segment without rebasing the timeline.

Full-length review reports progress, and cancellation discards partial evidence. The UI waits for
cancellation acknowledgment before allowing another analysis; closing the editor also cancels it.

The source ID, not recorder-group ID, restricts the ghost and clock icons. One proposed
relationship belongs to the entire target file, not independent per-channel curves. Other files
sharing that recorder are not previewed as moved. Supported runs and unverified intervals are
explicitly labeled **proposed, not applied or played** until accepted. Acceptance checks the cached
evidence, original participants, actual source headers, source tokens and current reference again;
it never binds old timing to newly registered source tokens. Submitted reference-projection values
are not authority: projection is recomputed against the fixed accepted reference.

### Persistence and audible application

Show schema 4 stores optional `TimeMapVersion.sourceCorrections` beside the unchanged strict
recorder map. Each curve records the source/reference IDs, source shape, measured support,
analysis digest and processing identity. It belongs to the entire selected file, not its recorder
group. Other files and existing clock authority are preserved. Correction targets participate in
the accepted-map inputs, placement/revision checks and canonical content digest even when their
recorder epoch has no supported clock map. Corrected files cannot become references for another
adaptive correction. Recorder-group timing edits refuse while file-local corrections remain.

Measured-only corrections retain correction version 1 and omit the optional segment kind, preserving
legacy decoding. Corrections containing only measured/`quietTransition` segments require correction
version 2. Any `anchorGuided` or `estimated` segment requires correction version 3; older applications
refuse the correction instead of silently interpreting its weaker timing provenance as independently
measured. All segment kinds and geometry participate in accepted-map identity and cache invalidation.
The unchanged native multichannel renderer handles the bounded quiet rate alongside measured
segments. Kind, correction version and intervals participate in the canonical accepted-map content
identity, shared listening/derived-audio caches, persistence and Undo/Redo.

Older shows require explicit C5 migration with an original-byte backup; older apps refuse schema 4
before silently ignoring its corrections. Acceptance/removal use the existing save-before-activate
ledger and native Undo/Redo. Waveform reprojection retains source-coordinate buffers; solid applied
strokes never bridge unsupported spans. Blue clock markers identify measured timing, orange waveform
markers identify quiet-only timing.

`ww-native-time-pitch-multichannel/1` uses one offline `AVAudioUnitTimePitch` at zero pitch shift
for all channels together, with the inverse of the source-to-aligned rate. Direct AudioUnit
render callbacks avoid a main mixer's surround remapping of independent recording channels.
The wrapper and PCM callback context stay alive through rendering and native uninitialization.
`WWDecode.PCMResampling` first performs nominal sample-rate conversion on already decoded planar
PCM, using explicit discrete channel labels and an identity channel map. This helper has no
source/file access; all actual media reads still use the witnessed read-only gateway. The native
pitch unit then operates at the destination rate, separately from the ordinary affine SRC path.

Canonical global five-second cache tiles, including negative time, are witness-bound,
revision-keyed and memory-admitted. Processing origins are anchored to each supported source
region in bounded twelve-source-second blocks, not reset to each transport/cache window.
Adjacent processing blocks share a 120 ms complementary crossfade; each has 120 ms input context.
This avoids the measured 0.09-0.12 amplitude jumps at five-second cache cuts in the earlier
per-tile implementation. Separate source reads never retain a long hull across unsupported gaps;
each native input remains below 15 seconds. Supported-region edges have 4 ms fades.
Render recipe/asset revision 2 invalidates the earlier mixer/per-tile audio without changing the
portable processing family or silently reusing its cached output.
Unsupported intervals are explicit silence, **not approximate or extrapolated timing**. Acceptance
requires a confirmation warning about this limitation. Listening and adaptive aligned segments
reuse exactly these tiles; adaptive segments have a distinct asset kind and explicit processing
identity, never a misleading ordinary-renderer label. Public export remains blocked by the existing M4 boundary.

Synthetic native checks cover duration, 440 Hz pitch, inverted/scaled channel relationships,
independent pulse identity in 8/16/32-channel banks, nominal 8/11.025/44.1/48/192 kHz conversion,
destination rates of 8/11.025/44.1/48/96/192 kHz, and both cache-cut and twelve-second
processing-block continuity. Stereo relationships retain
their strict amplitude check; the larger tone-bank check uses a one-output-sample-equivalent
440 Hz phase bound. Pulse conversion alone stays within one output frame; native pulse placement
at four seconds is checked against a separate 5 ms tolerance over ratios 0.98 through 1.02.
Increasing native overlap from 8 to 32 worsened that transient probe and was not retained.
The 1 ms acoustic-fit gate is **not** a 1 ms phase-vocoder transient guarantee or proof of
perceptual transparency on arbitrary speech.
The existing affine playback path is unchanged and is not relabeled as pitch-preserving.

`RecorderGroup.preferredAlignmentReference` is optional portable user preference, not measured
clock authority. Its Setup edit is undoable. Existing accepted references remain first; for a fresh
timeline, preferred eligible groups precede assigned speaker primaries and ordinary eligible order.
Preferred **already timed** speaker references outrank other matching sources; unaligned preferred
groups cannot bootstrap an accepted reference. No brand/name heuristic is used.

### Real-pair development evidence and limitations

An explicitly authorized software-capture/hardware-reference pair produced 4,449 attempted local
windows. Of these, 780 passed the adaptive quality gate. Replaying those unchanged observations
with the conservative non-overlap requirement yielded **9 supported runs covering 59 seconds**,
approximately **1.3% of the overlap**. This is not a usable whole-track adaptive correction.
Many strongly correlated active-speech windows failed NCC/PHAT method/polarity consistency, while
about half of all attempts measured silence. Neither silence nor a strong NCC score establishes
timing on its own. Failed observations were not promoted, and gaps were not interpolated.

A subsequent fresh `ww-adaptive-align/3` run measured all windows again and verified ephemeral
schema round-trip and bounded native multichannel application. It produced **254 supported runs,
782.250767 seconds (13 minutes 2 seconds), and 1,024 usable / 4,449 attempted windows**:
approximately **17.57% of the measured overlap**, not whole-track recovery. Silence and ambiguous
half-second correlations still account for substantial missing support; a window-status count
is not ground-truth speech coverage. The later direct-native/block-rendering changes have separate
native regressions; this earlier v3 application run does not validate their implementation.

The fresh v4 position-only alternative-grid run produced **300 runs, 890.125019 supported
seconds (14 minutes 50 seconds), and 1,069 usable / 4,449 attempted windows**. Its ephemeral
schema/native-application check passed using direct AudioUnit rendering and source-region blocks.
Of the still-inconsistent windows, 82 had unambiguous edge checks but an ambiguous shared middle
half-second. Three fresh four-second probes evaluated the longer-window v5 grid: it corroborated
two of those middle-window examples while retaining the third ambiguity. These small development
probes motivated a fresh full run, not promotion of old evidence.

That fresh `ww-adaptive-align/5` run produced **338 runs, 1,047.082772 supported seconds
(17 minutes 27 seconds), and 1,152 usable / 4,449 attempted windows**, approximately **23.5%
of the measured overlap**. Ephemeral schema round-trip and native multichannel application passed.
A separate direct time-domain correlation of actual corrected output against the fixed hardware
reference measured **NCC 0.940211 and -0.25 ms residual lag**, within its separate 5 ms native
tolerance. This checks one selected strong half-second passage inside a supported run, not all
rendered audio or whole-track recovery; the unsupported intervals still remain silent.

V5 recorded 2,014 `sharedSilence` and 266 `silent` windows: over half of the 4,449 attempts.
Of the remaining 2,169 windows, 1,169 had eligible status (1,152 passed grouping eligibility).
Neither that status-count proxy nor the supported-duration percentage is measured speech recall.
Of 800 subwindow-rejected observations, 247 had an individually sufficient canonical middle and
no strong-unique contextual contradiction. Only 138 also had consistently scored, same-delay
context throughout; the others included weak or ambiguous-but-disagreeing checks. These numeric
diagnostics motivated the stricter, separately versioned sequence measurement, not acceptance of
old failed observations.

The fresh v6 sequence run produced **312 runs, 1,104.138762 supported seconds (18 minutes
24 seconds), and 1,290 usable / 4,449 attempted windows**, with 138 sequence-tier windows in
72 supported runs. The same 2,280 attempts had quiet statuses. Ephemeral schema round-trip and
native multichannel application passed. Independent direct time-domain checks of corrected output
measured **NCC 0.940211, -0.25 ms** for the selected strong passage and **NCC 0.922816, 0 ms**
for a selected newly sequenced passage. Both use the separate 5 ms native tolerance. These are
two bounded passages, not qualification of every run or whole-track recovery.

Fresh centered speech-band energy measurements over a 114-second diagnostic interval found
49 weak checks around individually sufficient middles. Only 32 met all two-sided absolute,
relative-RMS and peak-amplitude guards; one-sided dropouts and stronger context were not assumed
quiet. The full fresh v7 run yielded **311 runs, 1,109.173263 supported seconds (18 minutes
29 seconds), and 1,321 usable / 4,449 attempted windows**, including 31 quiet-sequence
observations. Independent corrected-output checks passed for the strong and strict-sequence
passages above and for a quiet-sequence passage (**NCC 0.736922, -0.020833 ms**, 5 ms native
tolerance). This modest increase exposed the overlapping-ordinary-support issue addressed by
the separately versioned v8 selection, rather than justifying looser timing or quiet gates.

The fresh v8 run produced **315 runs, 1,116.556998 supported seconds (18 minutes 36 seconds),
and 1,321 usable / 4,449 attempted windows**. Of these, 288 used localized sequence support,
including 50 quiet-sequence observations, across 134 supported runs. Actual corrected output
passed independent direct-correlation checks for a strong passage (**NCC 0.934801,
-0.25 ms**), a strict-sequence passage (**NCC 0.959562, -0.25 ms**) and a quiet-sequence
passage (**NCC 0.894945, -0.020833 ms**), with the same separate 5 ms native tolerance.
Ephemeral schema/native application and original-integrity checks passed. The remaining
unsupported material is not established as silence, and this is still not whole-track recovery.

An additional fresh v8 run measured 100 ms activity bins throughout the overlap. It found
**1,802.3 seconds above the 0.0001 speech-band RMS threshold**, of which **1,033.2 seconds
(57.33%)** lay entirely inside supported runs. This is an amplitude proxy, not speaker-specific
speech recall. It confirms that the remaining unsupported material is not merely quiet time.
Thirteen individually sufficient complete-grid observations had unsupported centers; synthetic
controls reproduced the unconstrained-fitting refusal despite an admissible constant line.

The fresh v9 bounded-fit run produced **317 runs, 1,124.387748 supported seconds (18 minutes
44 seconds), and 1,321 usable / 4,449 attempted windows**, with 288 localized-sequence
observations across 137 supported runs. Above-threshold activity coverage rose to
**1,040.4 / 1,802.3 seconds (57.73%)**. Native direct-correlation probes measured **NCC
0.935788, -0.25 ms** for a strong passage, **NCC 0.959562, -0.25 ms** for a strict-sequence
passage, and **NCC 0.894945, -0.020833 ms** for a quiet-sequence passage. Schema/native
application and source-integrity checks passed. These selected passages do not establish
every run's rendered accuracy; roughly 42% of above-threshold activity is still unsupported.
There is no claim of whole-track recovery or permission to accept those unknown intervals as aligned.

A diagnostic-only 117-second interval compared independent half-second searches before changing
production acceptance. The 150 Hz view supplied 47 eligible / 152 attempted searches; the fixed
600 Hz view supplied 77 / 152 under the same NCC/PHAT, uniqueness and polarity gates. These counts
were not pooled into timing support. A first v10 spectral fallback increased above-threshold
activity support to 1,255.0 seconds, but an actual rendered-output probe had NCC **0.519824**,
below the unchanged 0.55 native check. That experiment did **not** qualify; its greater coverage
is not a successful alignment result. It motivated the additional independently sufficient
broad canonical-middle gate, rather than lowering the output threshold or picking a better probe.

The fresh v11 run produced **308 runs, 1,251.403498 supported seconds (20 minutes 51 seconds),
and 1,428 usable / 4,449 attempted windows**. It retained every v9 supported interval and added
**127.015750 seconds**, with exactly 107 changed observations, all carrying the new spectral proof.
Above-threshold activity support rose to **1,157.6 / 1,802.3 seconds (64.23%)**. The prior strong,
strict-sequence and quiet-sequence output checks retained their v9 results. All **83** eligible
bounded-interior spectral passages were additionally rendered and compared, yielding **NCC 0.586599-0.963096** and a
maximum absolute native residual of **1.25 ms**, inside the unchanged 0.55 NCC / 5 ms native
gates. These span the full available canonical broad-middle score range, not only the strongest
new example. Ephemeral schema/native application and original-integrity checks passed.
These are selected output passages, not
verification of every rendered region; approximately 36% of above-threshold activity remains
unsupported. Whole-track recovery is still unresolved.

The fresh v12 shorter-window/interval-counting run produced **316 runs, 1,276.527986 supported
seconds (21 minutes 17 seconds), and 1,437 usable / 4,449 attempted windows**. It retained every
v11 supported interval and added **25.124488 seconds** across 17 previously unsupported pieces.
Exactly nine observations changed, each carrying freshly measured one-second/quarter-window
proof; the independence-order fix additionally recovered sufficient existing mixed-length runs.
Above-threshold activity support rose to **1,179.8 / 1,802.3 seconds (65.46%)**. The additional
local-bound guard excludes otherwise insufficient long-window centers; the short proof does not
lend them unverified scope.

Output checks now include later positions in supported runs, not just their first four source
seconds. All **107** eligible interior spectral passages and **nine** new shorter-window passages
were rendered and compared. Spectral output NCC ranged **0.576194-0.963096**, with maximum
absolute native residual **1.479167 ms**. Shorter-window output NCC ranged **0.735064-0.882942**,
with maximum absolute native residual **0.75 ms**. Every probe passed the unchanged 0.55 NCC /
5 ms native gates, and exact serialized replay reproduced the complete final timing result.
These half-second probes do not verify every rendered sample or establish whole-track recovery:
approximately **34.54%** of above-threshold activity remains unsupported and would still render
as explicit silence after acceptance.

The fresh v13 quiet-transition run preserves the **entire v12 measured timing result exactly**:
316 measured runs, 1,276.527986 measured seconds and 1,437 / 4,449 usable windows. It separately
adds **127 quiet-only transitions totaling 192 seconds (3 minutes 12 seconds)**. Both target
channels were checked, along with the selected reference channel. Directly measured activity
coverage remains **65.46%**; the extra quiet intervals must not be reported as additional measured
speech. Only 0.2 seconds of the added quiet intervals also crossed the separate activity diagnostic's
amplitude threshold, illustrating why neither energy measure is a speech label.

All 107 spectral and nine shorter-window native speech-output probes still pass. Exact numeric
replay reproduces the complete measured-plus-quiet result. Synthetic native checks cover audible
quiet rendering, shared stereo relationships, persistence and removal/Undo; analysis controls cover
active other channels, opposite-channel cancellation, one-sided dropout, low-level bursts,
transients, bass/tones, differing room-tone floors, awkward sample rates/chunk sizes, inclusive
50 ms / 60 second bounds, cancellation, and a reference changing after its energy pass completes.
This improves quiet continuity, not recovery of the remaining unmatched speech.

The final v14 development runs preserve every v13 measured run, counter and quiet witness exactly.
They add **122 anchor-guided short regions totaling 36.5 seconds**, based on 10,365 fresh observations.
Fully supported 100 ms above-threshold activity bins increase from **1,179.8 to 1,205.6 / 1,802.3
seconds (65.46% to 66.89%)**, counting measured and anchor-guided acoustic support, not quiet
transitions or estimates. This is still an amplitude proxy, not verified speech recall.

The default proposal places **1,505.027986 seconds (33.81%)** of the 4,451.494312-second compared
interval: independent measurements, quiet transitions and the separate anchor-guided regions.
Opting into estimated timing adds **488 intervals / 2,842.666098 seconds**, bringing total placement
to **4,347.694084 seconds (97.67%)**. Approximately **93.35%** of above-threshold activity bins lie
fully inside this optional playback coverage. These larger numbers describe retained estimated
playback, **not acoustically verified alignment**; remaining short steep transitions and unsupported
ends are not filled. Estimated gaps can still contain misaligned or missing speech.

Both default and estimated modes were separately applied to ephemeral documents and rendered.
All **181** quarter-second probes spanning the 122 newly guided regions passed the unchanged native
NCC >=0.55 and residual <=5 ms gates. Default-mode minimum NCC was **0.630416**; estimated-mode
minimum was **0.642515**; both had maximum absolute residual **0.770833 ms**. All 107 existing
spectral and nine shorter-window output probes still passed. Complete anonymous replay reproduced
the result without reading media. These selected, overlapping output probes cover the proposed new
regions but are not additional independent timing votes or verification of every rendered sample.

An earlier v14 prototype admitted canonical quarters at NCC 0.65 and failed a native output probe
at **0.536004**. It was not accepted as a qualified result. Requiring the canonical quarter to score
at least 0.75 provides the stronger output witness used in the final runs; the independent regions,
ordinary estimator and native output gates were not weakened.

Original hashes and metadata remained unchanged, and private decoded caches were removed.
Numeric replay now refuses evidence from a different adaptive version rather than relabeling
old failed observations as a new algorithm. These are development results, not real-media
qualification, frozen holdout evidence, or a claim that this recording pair is solved.
The initial three-subwindow implementation still required long uninterrupted full-window runs and
was worse: a fresh run supported only one eight-second region. This led to the separately versioned
subwindow-aware independence logic above, rather than lowering ordinary v4 confidence gates.

### Research informing the next measurement

WebRTC's public [acceleration](https://github.com/webrtc-mirror/webrtc/blob/main/modules/audio_coding/neteq/accelerate.cc)
and [preemptive expansion](https://github.com/webrtc-mirror/webrtc/blob/main/modules/audio_coding/neteq/preemptive_expand.cc)
implementations remove or repeat short pitch-related portions with overlap-add crossfades.
This demonstrates why conferencing timing can differ from a steady hardware clock; it does not
identify the implementation or prove the cause of changes in this authorized recording pair.
Simply increasing the clock-rate limit did not reveal coherent additional local fits in the v5
diagnostic and was not implemented.

[AudioLabs' DTW variants](https://www.audiolabs-erlangen.de/resources/MIR/FMP/C3/C3S2_DTWvariants.html)
document how unconstrained paths can repeat or omit material, while
[librosa's synchronization example](https://librosa.org/doc/0.10.2/auto_examples/plot_music_sync.html)
illustrates sequence-level alignment. Such paths can guide a search, but are not millisecond
waveform evidence and do not justify interpolating through unknown audio. The v6 experiment
instead retains individually sufficient local correlations and tests their sequence with the
existing residual, disjointness, monotonicity and contradiction controls.
Librosa's [DTW API](https://librosa.org/doc/0.10.2/generated/librosa.sequence.dtw.html)
exposes allowed steps, step penalties and a global search band: these are useful constraints on
a future feature-path proposal, not waveform acceptance evidence. The BBC tool itself describes
typical accuracy around 10 ms, so its MFCC offset is likewise coarse guidance rather than proof
of the separate 1 ms acoustic-fit requirement.

Further research considered [generalized correlation/SCOT weighting](https://doi.org/10.1109/TASSP.1976.1162830),
[coherence-based delay estimation](https://doi.org/10.1109/PROC.1987.13723), and
[frequency-sliding sub-band GCC](https://arxiv.org/abs/1910.08838). These can inform a future search
or diagnostic. An extra coherence-weighted phase-slope fit was not added as an independent vote:
it reuses overlapping waveform content, and an unknown filter's group delay cannot uniquely
establish a separate transport/clock delay. Overlapping STFT frames are not independent timing
supports either. The current improvement instead uses fresh, explicitly disjoint waveform checks
and actual corrected-output comparisons; no paper is claimed to validate this exact recording pair
or the chosen acceptance thresholds.

## Running the checks

`scripts/test.sh` includes the new heavy suites in its existing serialized estimator pass.
For focused work, use the same package scratch path and bounded runner:

```sh
umask 022
WW_ESTIMATOR_TESTS=1 WW_ESTIMATOR_MAX_CONCURRENCY=2 \
  swift test --package-path Packages/WaveWranglerKit --scratch-path .build/swiftpm \
  --jobs 4 --no-parallel \
  --filter 'WWAutoAlignTests|WWAlignPipelineTests|WWAlignEstimateTests|ForbiddenAPITests'
```

Do not set `WW_ESTIMATOR_HOLDOUT`; frozen holdouts are not routine regression commands.
Build with `WW_DERIVED_DATA=.build/DerivedDataAdaptiveAlignment scripts/build.sh` when the user's existing
app is running from another product directory. Headless package/app unit checks do not require
launching, quitting or controlling that app. GUI testing remains subject to the existing separate-host
lease and synthetic-fixture policy.

### Explicitly authorized local-pair diagnosis

`WWLocalEpisodeValidationTests/LocalAlignmentPairTests` is disabled unless both
`WW_LOCAL_ALIGNMENT_REFERENCE` and `WW_LOCAL_ALIGNMENT_TARGET` name explicitly authorized local files.
It checks channel 1 only, using the same selected-speaker pipeline in each direction. Set
`WW_LOCAL_SCRATCH_DIR` to a fresh empty local directory outside the repository, cloud-synced folders
and either source folder, then run:

```sh
swift test --package-path Packages/WaveWranglerKit --scratch-path .build/swiftpm \
  --jobs 4 --no-parallel --filter LocalAlignmentPairTests
```

Supply paths at run time, never in committed commands or fixtures. The harness does not enumerate
the episode, launch the app, transcribe, play audio, or change a real show. It refuses
unmaterialized/non-local sources. Decoding uses WWDecode; read-only SHA-256 plus metadata comparisons
verify both originals on exit, including failure paths. It deletes its private derived cache and
retains only anonymous numeric JSON reports, not media, in the guarded scratch directory.

Set `WW_LOCAL_ALIGNMENT_ADAPTIVE=1` to measure the source-local candidate with the supplied reference
held fixed (one direction only). This writes `adaptive.json`, including all attempted-window
classifications and supported runs. By default it does not accept timing or render audio. Additionally
set `WW_LOCAL_ALIGNMENT_APPLICATION=1` to round-trip acceptance in an ephemeral synthetic document and
render a bounded supported window through the native multichannel path. It still never saves a real
show, plays audio, or modifies either original. Do not combine adaptive mode with interval-only variables.
Actual-output failures abort application diagnosis before its success message; cleanup and original
integrity checks still run.

To regroup an existing anonymous `adaptive.json` report without reading the recordings again, set
`WW_LOCAL_ALIGNMENT_REPLAY` to that report and select `LocalAdaptiveEvidenceReplayTests`. This
separate opt-in preserves every recorded window classification and runs only the current local
grouping rules. It writes a new `.regrouped.json` report and refuses to overwrite an existing one.
Do not set the source-file opt-ins for this numeric-only command.

For closer inspection, additionally set `WW_LOCAL_ALIGNMENT_START`, `WW_LOCAL_ALIGNMENT_END`
and `WW_LOCAL_ALIGNMENT_OFFSET`. These select a four-to-120-second interval in the target's source
clock and a finite offset hint from prior measurements. This mode probes headers and measures
overlapping two-second windows at nominal rate, without full-track indexing or fitting/accepting a
map. Overlapping windows are diagnostics, not independent fit coverage. Never weaken production
gates or label variable transport latency as recorder drift merely to make a local pair pass.
With interval mode and `WW_LOCAL_ALIGNMENT_TEMPORAL=1`, additionally set
`WW_LOCAL_ALIGNMENT_ENERGY=1` to write anonymous `energy.json` containing centered speech-band
RMS and peak diagnostics for each measured subwindow. These measurements do not accept timing
or label speech. The source opt-ins, fresh-scratch requirement and original-integrity checks
still apply.
Alternatively set `WW_LOCAL_ALIGNMENT_LOCALIZED=1` in interval mode to compare diagnostic half-second
NCC/PHAT searches in the two fixed speech bands, the normal adaptive measurement and separately
labeled upper-band measurements. Results stay in anonymous `dense.json`, with per-method counts;
they are never pooled, fitted or accepted. This opt-in cannot be combined with adaptive full-track
mode, energy diagnostics or application. It does not expose a new app setting or acceptance method.
In adaptive full-pair mode, that energy opt-in instead writes `activity.json`: 100 ms
source-channel-1 activity bins, decoded in bounded 30-second batches with filtering context.
The report counts above-0.0001 speech-band RMS duration and the subset entirely inside supported
runs. This is an amplitude-based diagnostic, not a VAD, speaker attribution or measured speech recall.

**Limits:** indexing every frame at feature resolution is not precise verification of every frame.
Selected fine passages can miss a short edit/restart between observations. The index is per-channel,
not a whole-library identification service, and evidence may be insufficient for highly reverberant,
weak, repetitive or channel-misassigned recordings. A good result remains a reviewable acoustic
proposal. These fixtures do not verify the user's entire real recording or qualify a general
microphone/room envelope.

## Design references

- [BBC audio-offset-finder](https://github.com/bbc/audio-offset-finder): standardized MFCC correlation
  for coarse discovery. This candidate uses related log-band spectral features, not that implementation.
- Knapp and Carter, [The generalized correlation method for estimation of time delay](https://doi.org/10.1109/TASSP.1976.1162830):
  the GCC-PHAT fine-delay design reference.
- [RANSACRegressor](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.RANSACRegressor.html):
  consensus-fitting reference; the native bounded fit does not require a Python runtime.
