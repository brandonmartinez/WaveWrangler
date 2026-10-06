# WW-017 evidence: discontinuity segmentation, calibration and `m2-freeze-discontinuity`

**Status: calibration gate PASSED on synthetic signals on this host; frozen; HOLDOUT NOT RUN. No `clockApproved`.**

**Scope.** `WWAlignSegment` (Packages/WaveWranglerKit) is a new pure module that sits between the frozen WW-016
estimator and the time map. It imports only Foundation, `WWCore`, `WWTimeMap` and `WWAlignEstimate`, and calls
`WWAlignEstimate` through its public API only. Under `m2-freeze-estimator` the estimator's sources and tests are
unchanged. `SegmentPurityTests` bans the following in the module, and the repo-wide decode scan covers it too:
- file, content and decode APIs;
- random-number, UUID, shuffle and hashing APIs, wall clocks and concurrency;
- `RecordingEpochID()` minting outside its two known sites (one per region kind). Those IDs are opaque labels; every
  numeric result (positions, sizes, scores, maps) is deterministic, and scoring never compares epoch IDs;
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

**Per-case records.** Setting `WW_SEGMENT_RECORDS_DIR` makes the same suites write one canonical JSON line per case
(seed, truth, per-plant status and detected kind, counts, residuals, failures). The committed records are
[`ww-017/calibration.jsonl`](ww-017/calibration.jsonl), [`ww-017/floor.jsonl`](ww-017/floor.jsonl) and
[`ww-017/edge-silence.jsonl`](ww-017/edge-silence.jsonl). Their SHA-256 values and totals are in the freeze record's
`calibrationSummary`. A rerun that wrote them produced per-case lines identical to the earlier run. The cheap test
`committedRecordsReproduceTheReportedCalibration` checks the following without decoding audio:
- the hashes;
- each record's seed and truth against the frozen plan;
- the recomputed totals against the reported ones;
- the gates again.

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
- The harness keeps at most `WW_SEGMENT_MAX_CONCURRENCY` cases in flight. The default is 4, valid values are 1–4 (it may only lower),
  and it is never derived from the processor count. `SegmentBudgetTests` asserts the default and the bound.
- The heavy suites run in their own serialized `--no-parallel` pass, gated by `WW_SEGMENT_TESTS=1`.
- **CI runs only the gated calibration** (coordinator decision 2026-10-06; `timeout-minutes` stays at 45).
  - `scripts/test.sh` reads `WW_SEGMENT_SWEEPS`: `1` runs calibration, the floor sweep and edge silence; `0` runs
    calibration only.
  - It defaults to `1` locally and `0` when `CI=true`, and the workflow also sets `0` explicitly. The serialized pass
    took 880 s on CI with all three suites.
  - With the sweeps off, CI still runs the always-on cheap test `committedRecordsReproduceTheReportedCalibration`, which
    re-checks the committed floor and edge-silence records (hashes, truth against the plan, totals, invariants).
  - The sweeps themselves run in every local full `scripts/test.sh`, including before each handoff.
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

## Frozen holdout (2026-10-06): FAIL

This is separate from the calibration above. The frozen `m2-freeze-discontinuity` holdout ran once, with no
`WW_SEGMENT_MAX_CONCURRENCY` override (the frozen default is 4), on commit
`f835948b1500a1af471c68050e085070464c712a` (Apple M5 Max, 18 cores, 128 GiB, macOS 27.0.1 (26A434), Xcode
27.0 (27A266a), Swift 6.4). It started at 2026-10-06T17:19:40Z and finished at 2026-10-06T17:32:16Z. The frozen
trees were `WWAlignSegment` `08bc77339aee0ccb9294e5c1610529ef5e088320`,
`WWAlignSegmentTests` `b4d12045d3fe0e2c913f4c3545bec56f0d8f9ce0`, `WWAlignEstimate`
`8efd588a6b57dc56bf7eafa1ccf2c7709253f3a9`, `WWTimeMap`
`24c7aadfbf1470c8555542061ab08eb23e37325b`, and `WWCore`
`c310389c4b41ebde80c5dabaea12fd5376f5d9ba`.

- **PASS:** 130/130 planted discontinuities flagged; 0 unsupported-only, 0 bridged, 0 bridging regions, and 0 silent bridges.
- **FAIL:** negatives false-split 3/50 (0.060) against the frozen maximum of 0; `transient#6`, `transient#13`, and `silenceGap#4`.
- **PASS:** 0 positive/monotonic, gap-inverse, or retention failures; supported worst nearest-rank p95/max was 1.078/1.096 ms, within the WW-016 5/10 ms gate.

The full verbatim run log (including every case and UTC start/end lines) is
[`ww-017/holdout-raw.txt`](ww-017/holdout-raw.txt). The unedited canonical case records are
[`ww-017/holdout.jsonl`](ww-017/holdout.jsonl), SHA-256
`c26445d14e4b8c64a587c4f07c37debd75514f2113bdb227087fd60e2949e6b7`
([`holdout.jsonl.sha256`](ww-017/holdout.jsonl.sha256)); the raw-log SHA-256 is
`ae8dbd818d6deec418deada812e6426c9c9a050bb2f8fd9cc81b8addcaf3d812`. This failed holdout does not authorize
`clockApproved`; mapped regions remain acoustic proposals.

## Freeze revision 2 (2026-10-06): calibration PASS; HOLDOUT NOT RUN

**Diagnosis.** The unchanged rev-1 holdout records above show `transient#6` produced an `unresolved` detection
whose slope-intersection bracket expanded to the entire 58.65 s span (zero mapped regions). `transient#13` and
`silenceGap#4` each produced one boundary near the file end, at 61.58 s of 65.58 s and 51.63 s of 53.63 s
respectively. The records expose no individual window offsets, so the suspected mechanism is short-lived
misleading fits after target-only activity or loss of shared sound, not a proven reconstruction of those windows.
None of these detections alone establishes a persistent change of clock. The failed cases were diagnosed from
the committed records only; their seeds were not rendered, replayed or used for calibration.

**Revision.** `ww-align-segment/2` requires each fitted run to cover at least 4 s between its first and last
eligible window centre before it can establish a boundary. Short coherent runs stay unresolved, not mapped as
another clock. The existing half-window margins, conservative brackets, per-candidate estimator agreement and
image-overlap demotion remain. The unchanged gates and the new, disjoint case seeds/counts are frozen in
[`m2-freeze-discontinuity-2`](../fixtures/m2-freeze-discontinuity-2.json), which supersedes rev 1 without
altering its FAIL evidence.

**Rev-2 calibration** (70 fresh cases; serialized `--no-parallel`, four cases maximum in flight): 38/38 planted
discontinuities flagged with expected kind, 0 bridged plants/regions, 0 silent bridges, 0/36 false splits (clean
0/6; target-only transients 0/15; silence gaps 0/15), 0 positive/monotonic, inverse or retention failures;
supported worst nearest-rank p95/max 1.045/1.052 ms versus the unchanged 5/10 ms WW-016 residual gate.
The six edge-silence regressions flagged 6/6, bridged 0, worst max 0.744 ms. The reported-only 30-case floor
sweep bridged 11 sub-class-threshold steps/rate changes (max residual 0.985 ms); it does not replace the planted
class gate. Raw canonical per-case records and SHA-256 values are
[`calibration-2.jsonl`](ww-017/calibration-2.jsonl) (`ddf9a3232d1bac9b567321e726fc89cffbcc5ff28d5114dd1bf5eb56b2051ecc`),
[`floor-2.jsonl`](ww-017/floor-2.jsonl) (`2d85df8701fef50a1af03fbec692ad62146024433e486cd5ffe20e541dca2bc4`)
and [`edge-silence-2.jsonl`](ww-017/edge-silence-2.jsonl)
(`28cc677d486824d289ea524c82f4075064b6879afc1b74e23f5a63e4b5aa73ca`).

### Rev-2 holdout (2026-10-06): PASS

This separate, one-time run used the frozen 165-case/130-plant split on
`d1fdd446ed2c2faab6c0365bab6ad9259d3f0bc9` (Apple M5 Max, 128 GiB, macOS 27.0.1
(26A434), Xcode 27.0 (27A266a), Swift 6.4), from 2026-10-06T19:09:11Z to
2026-10-06T19:22:05Z. Frozen trees matched: `WWAlignSegment`
`cdd2da1e2134d46221a67ced1fd9efd857ae2d40`, `WWAlignSegmentTests`
`68ddb5e0b66a0e43c2c34fd625fca4deb70da715`, `WWAlignEstimate`
`8efd588a6b57dc56bf7eafa1ccf2c7709253f3a9`, `WWTimeMap`
`24c7aadfbf1470c8555542061ab08eb23e37325b`, and `WWCore`
`c310389c4b41ebde80c5dabaea12fd5376f5d9ba`.

- **PASS:** 130/130 plants flagged, 0 unsupported-only, 0 bridged, 0 bridging regions, and 0 silent bridges.
- **PASS:** negatives false-split 0/50 against the frozen maximum of 0.
- **PASS:** 0 monotonicity, gap-inverse, retention, or residual-gate failures; supported worst nearest-rank
  p95/max was 1.015/1.016 ms, within the unchanged WW-016 5/10 ms gate.

The full verbatim dated log is [`ww-017/holdout-2-raw.txt`](ww-017/holdout-2-raw.txt), SHA-256
`c2f45e63206819dc94dc180eb63b9e7ef9564013c090d8c41ff1aad0619e015c`. The unedited canonical records are
[`ww-017/holdout-2.jsonl`](ww-017/holdout-2.jsonl), SHA-256
`aabc8fe5a4b568a20d72e7c34c0c84ed0aa333d7430225413074a8d64978b3cd`
([`holdout-2.jsonl.sha256`](ww-017/holdout-2.jsonl.sha256)). This synthetic evidence does not qualify real
recordings; mapped regions remain acoustic proposals and no map is `clockApproved`.
