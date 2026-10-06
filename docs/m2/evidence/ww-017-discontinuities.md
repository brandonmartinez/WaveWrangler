# WW-017 evidence: discontinuity segmentation, calibration and `m2-freeze-discontinuity`

**Status: calibration gate PASSED on synthetic signals on this host; frozen; HOLDOUT NOT RUN. No `clockApproved`.**

**Scope.** `WWAlignSegment` (Packages/WaveWranglerKit) is a new pure module that sits between the frozen WW-016
estimator and the time map. It imports only Foundation, `WWCore`, `WWTimeMap` and `WWAlignEstimate`, and calls
`WWAlignEstimate` through its public API only. Under `m2-freeze-estimator` the estimator's sources and tests are
unchanged. `SegmentPurityTests` bans the following in the module, and the repo-wide decode scan covers it too:
- file, content and decode APIs;
- randomness, wall clocks and concurrency;
- `clockApproved`;
- probability wording.

`DiscontinuitySegmenter.segment` takes one recorder group's declared span, the decoded reference and target
buffers, and an estimator request. It returns:
- a validated `GroupTimeMap`, in which every region is its own epoch;
- typed detections;
- typed unsupported regions.

**Algorithm and outputs.** The segmenter runs in these steps:
1. Run dense, overlapping 8 s estimator tiles. Each eligible window gives one (group-clock centre, offset) point.
2. Split by recursive least-squares into two lines until every piece fits one line within 0.5 ms. Islands of
   unresolved windows stay unsupported.
3. Bracket each boundary from window evidence: `[cL − ½window − |jump|, cR + ½window + |jump|]`. For a slope change
   it is also widened to where the two lines are within 2 × tolerance.
4. Drop brackets and half-window edge margins from the candidates. A candidate must be at least 4 s long.
5. Re-estimate each candidate with the frozen estimator on exactly its frames. Keep it only if the estimator
   proposes, and agrees with the segment line within 1 ms.
6. Demote overlapping images to unsupported (`imageOverlap`).

What the output contains:
- **Mapped regions** carry `acousticConsistentProposal` segments.
- **Unsupported regions** carry one of these causes: `discontinuity`, `unresolvedWindows`, `noEvidence`,
  `edgeMargin`, `tooShort`, `estimatorAbstained`, `lineDisagreement` or `imageOverlap`. A gap therefore restarts the
  epoch, and WWTimeMap gives it no inverse. Anything that cannot be localised to the gate's precision stays
  unsupported or manual.
- **Detections** carry:
  - the kind (`offsetStep`, `slopeChange` or `unresolved`);
  - the bracket and its frames, and the position;
  - the step in ms and the slope change in ppm;
  - the window counts and residuals;
  - the median peak scores. These are coefficients, never probabilities.

The occurrence and the declared epoch are retained (on the first mapped region). The identifier is
`ww-align-segment/1`; non-default parameters are stamped `+custom`.

**Fixtures and scoring.** The generator is seeded with SplitMix64 and lives in test code only. It covers 9 strata,
recorded in [`m2-fixture-registry.json`](../fixtures/m2-fixture-registry.json) as `M2-SEG-*`:
- clean;
- near-miss transient (loud clicks or bursts heard only by the target);
- near-miss silence gap (3–8 s with the scene removed or the target muted, and no clock change);
- dropped samples (5–500 ms);
- inserted samples (5–500 ms of noise or repeated content);
- clock step (±5–500 ms);
- recorder restart (0.3–1.2 s pause plus a new rate);
- rate change (300–400 ppm);
- compound (two kinds).

Each case has independent piecewise truth, and inserted frames have no truth. `Scoring.swift` scores against that
truth only:
- **Flagged:** a detection bracket overlaps the plant.
- **Bridged:** one mapped region holds frames on both sides of the plant, or holds any inserted frame. A bridge
  whose residual is inside the gate is a *silent* bridge.
- **Residuals:** `|map(n) − truth(n)|`, taken every 1 s plus each region's last frame.
- **Monotonicity:** rate > 0, and the forward map strictly increases.
- **No inverse in gaps:** 5 instants inside every skipped gap must not invert, and grid instants must invert within
  10 ms of truth and never into inserted frames.
- **Retention.**

`SegmentScoringTests` (9 cheap tests) checks the scorer itself. Each check must fail on fabricated maps that:
- bridge silently or loudly;
- map inserted frames;
- invert skipped instants;
- miss the residual gate;
- split a negative;
- lose retention.

**Calibration** (master seed `0x57571700CA11B000`, 48 cases, 38 plants). It ran on an Apple M5 Max (18 cores,
128 GiB) under macOS 27.0.1 (26A434), Xcode 27.0 and Swift 6.4, as a debug build. The command was the serialized
segment pass of `scripts/test.sh`:

`WW_SEGMENT_TESTS=1 swift test --no-parallel --filter 'WWAlignSegmentTests\.(CalibrationTests|FloorSweepTests|EdgeSilenceTests)'`

With the compute cap (4 cases in flight) the wall times were 186 s for calibration, 112 s for the floor sweep and 24 s for edge silence. Every per-case line is identical to the pre-cap run.

| stratum | cases | plants flagged / unsupported / bridged | false splits | spurious det. | mean coverage | worst p95 / max ms | position error median / max s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| clean | 6 | – | 0/6 | 0 | 0.94 | 0.964 / 0.964 | – |
| transient | 4 | – | 0/4 | 0 | 0.90 | 0.883 / 0.884 | – |
| silenceGap | 4 | – | 0/4 | 0 | 0.93 | 0.901 / 0.901 | – |
| dropped | 6 | 6 / 0 / 0 | – | 0 | 0.89 | 0.996 / 0.996 | 0.24 / 0.51 |
| inserted | 6 | 6 / 0 / 0 | – | 0 | 0.87 | 0.820 / 0.820 | 0.21 / 0.79 |
| clockStep | 6 | 6 / 0 / 0 | – | 0 | 0.88 | 0.858 / 0.858 | 0.26 / 0.81 |
| restart | 6 | 6 / 0 / 0 | – | 0 | 0.85 | 0.602 / 0.603 | 0.29 / 0.69 |
| rateChange | 6 | 6 / 0 / 0 | – | 1 | 0.62 | 0.983 / 0.983 | 0.08 / 0.19 |
| compound | 4 | 8 / 0 / 0 | – | 0 | 0.79 | 0.902 / 0.902 | 0.18 / 0.64 |

Gate results (`SegmentRunner.gateFailures`):
- **PASS:** 38/38 plants flagged, each with the expected kind.
- **PASS:** 0 bridged plants, 0 bridging regions and 0 silent bridges.
- **PASS:** every mapped region is within the WW-016 gate (p95 ≤ 5 ms, max ≤ 10 ms). The worst is 0.996 ms.
- **PASS:** 0 monotonic, inverse or retention failures.
- **PASS:** false splits 0/14.

The false-split threshold is frozen at **0**. The measurement was 0/14, and a split on a negative only costs
coverage, so the strictest value costs nothing to keep and any regression shows up.

The one spurious detection is on rateChange#1, a second whole-span `slopeChange`. It leaves that case fully
unsupported (coverage 0). That outcome is conservative, not a gate failure. It explains the rate-change stratum's
low coverage, along with the wide slope-change brackets (7–9 s).

**Floor sweep** (reported, not gated; 30 cases; seed `0x57571700F1000000`).

| planted size | flagged | bridged | bridged-case max residual |
| --- | --- | --- | --- |
| steps ±2 and ±5 ms | 8/8 (`offsetStep`) | 0 | – |
| step ±1 ms | 4/4 (3 as whole-span `slopeChange`, coverage ≤ 0.11) | 0 | – |
| step ±0.5 ms | 2/4 | 2/4 | 1.130 ms |
| step ±0.25 ms | 0/4 | 4/4 | 0.734 ms |
| rate change 100–300 ppm | 6/6 (`slopeChange`) | 0 | – |
| rate change 25–50 ppm | 0/4 | 4/4 | 1.135 ms |

Every bridged floor case lies below the planted class ranges, and it stays within 1.2 ms of truth, inside the WW-016
gate. The floor sweep is not the silent-bridge gate. Steps below the 0.5 ms split tolerance are absorbed into a
single map by design.

**Edge silence** (heavy pass, gated). The suite takes the first dropped, clockStep and restart calibration cases and
mutes the target for 1.2 s just after, or just before, the plant, giving 6 cases. Results:
- 6/6 flagged, 0 bridged, worst max 0.996 ms.
- Position error grows to 0.46–1.31 s, because windows that straddle the jump hear only one side.

**Mutation checks.** Each mutant was applied, built and tested, then reverted. Sources were confirmed unchanged
afterwards.

*Scorer and harness: 21/21 caught.*
- Bridged-plant detection, bridging count, silent count, and bridging in hardFailures.
- The skipped-instant inverse probe, the inserted-frame inverse, and the residual gate (off, and doubled).
- Both false-split clauses.
- The regions-end, declared-epoch and identifier retention checks.
- The spurious count and detection association.
- All three gateFailures branches.
- Concurrency default 8, unbounded runner, and unclamped env.

*Freeze record: 8/8 caught by `SegmentFreezeTests`.*
- Calibration seed, holdout count, gate p95, false-split gate, and a parameter in the record.
- A registry ID.
- A code parameter default.
- A holdout seed equal to the calibration seed.

The tree pin fails on any edit or untracked file.

*Segmenter: 8 of 14 mutants caught.*

| mutant | caught by |
| --- | --- |
| split accepts any range | units |
| island absorb without fit | units; false-split rate 0.333 |
| merge without fit | units |
| no slope-intersection widening | rateChange#0 silently bridged (calibration case) |
| brackets not cut from candidates | rateChange#0 silently bridged (calibration case) |
| request validation off | units |
| parameter validation off | units |
| no edge trim and no bracket margins | edge-silence suite: all 6 cases bridged, max 22.7–45.8 ms |

Not caught, all six reported honestly:
- **No |jump| widening; no edge trim; both together.** These layers are redundant behind the bracket's half-window
  margin.
- **`tooShort` off.** The estimator abstains on short candidates anyway.
- **Agreement check always true.** It never triggered on these fixtures.
- **Image-overlap guard off.** This fails closed: WWTimeMap throws `overlappingEpochs`.

**Compute budget** (user-directed 2026-10-06):
- The harness keeps at most `WW_SEGMENT_MAX_CONCURRENCY` cases in flight. The default is 4, valid values are 1–16,
  and it is never derived from the processor count. `SegmentBudgetTests` asserts the default and the bound.
- The heavy suites run in their own serialized `--no-parallel` pass, gated by `WW_SEGMENT_TESTS=1`.
- The holdout is gated by `WW_SEGMENT_HOLDOUT=1`.

**Freeze and limits.**
[`m2-freeze-discontinuity.json`](../fixtures/m2-freeze-discontinuity.json) records the following:
- the recipe, truth, seeds and counts (calibration 48 / 38 plants; holdout 165 cases / 130 plants, 50 negatives);
- the gate values;
- the frozen parameters;
- the pinned trees;
- the holdout procedure.

The holdout is a separate PR after merge.

This PASS covers only synthetic signals with plants in the frozen size ranges. It does not qualify any real
recording, codec or device. It authorizes no `clockApproved`. Mapped regions remain acoustic proposals, so WW-016
holdout status and the manual-epoch fallback still govern production use.
