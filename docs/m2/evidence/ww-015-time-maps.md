# WW-015 evidence: clock epochs, coordinate maps and supported inverses

**Scope.** `WWTimeMap` (Packages/WaveWranglerKit) is a pure value-type module (Foundation + WWCore only; no I/O, no
Dates/URLs/tasks, no floating point in map code — `PurityTests` enforces this). It provides occurrence → epoch spans →
group clock → positive piecewise affine segments → one aligned timeline, with an explicit `TimelineReference`
(group, epoch, occurrence). **Conventions:** `u = n/F + e`, `t = a·u + b`. All values are exact `Int128` rationals.
`ppm = 1e6·(a − 1)`, and positive ppm means the group clock runs slow, so its content lands later. Clock pitch is
`1/a`; there is no time-stretch parameter. Positive lag L means the event is L frames *later* in the target
(`b = −L/F`). The only rounding is half-up quantisation `floor(x + ½)` of an exact inverse to a source frame.
Envelope: F ≤ 2^20, frames ≤ 2^40, parameter denominators ≤ 2^40, |time| ≤ 2^31 s, a ∈ [½, 2]. **What construction
proves:** forward mapping of every placed frame, and inversion of every instant inside a span's hull whose canonical
denominator is ≤ 2^20 (all `k/G` output grids with G ≤ 2^20), fit `Int128`. It checks `d·H·G + |c|·G` and `p·G`
(H = ⌈max |hull|⌉, G = 2^20) and refuses the map otherwise. Each term is necessary; a test gives a witness map for
each. Inverting an instant with a denominator above 2^20 is exact but may throw `exactArithmeticEnvelopeExceeded`.
The proof is conservative: it refuses many maps whose parameter denominators are all near 2^40.
**Synthetic truth** (seed `0x57573031355f544d`, generator and oracle in test code, using `Double` only to *pick*
parameters): 1,500 timelines; 2,999 groups; 6,636 mapped and 907 unsupported epochs; 14,315 segments; 5,945
occurrences; 11,434 spans; up to 238,955,040,683 frames; |ppm| up to 1,000,000. Results:
- **Forward round trips:** 96,877 frames, all exact (frame → aligned → frame).
- **Arbitrary aligned instants:** N = 146,170 inverted. Quantisation distance from the exact inverse: **max 0.5,
  p95 (nearest-rank) 0.4664** source frames.
- **Truth classification:** forward probes returned 15,070 `.gap`, 10,203 `.unsupported` and 53,611
  `.outsideCoverage`. Inverse probes returned 14,497 `.gap`, 3,244 `.unsupported` and 23,722 `.outsideCoverage`.
  Every result matched the oracle; nothing was extrapolated. An inverse `.gap` always lies between adjacent spans,
  and the forward map agrees. An instant where unsupported spans could lie returns `.unsupported`, never a gap
  that skips them. That covers instants between mapped spans, before the first and after the last. Each listed
  candidate span maps forward to `.unsupported` with the same epoch and reason.
- **Hostile denominators** (seed `0x57573031355f4744`): 1,000 maps with a, e and b denominators up to about 2^40,
  coprime to 3, 5 and 7. 899 were refused at construction and 101 accepted. Every one of 2,727 probed 44.1 kHz,
  48 kHz and random-G grid instants inside an accepted map's hull inverted without throwing. Each was bracketed by
  the forward images of frames f ± 1 and lay within half a frame in aligned time. The review counterexample
  (F = 44100, t = 5686619777/48000) is refused.
- **Envelope extremes:** 2^40-frame occurrences round-trip at 15 rate ratios from −500,000 to +1,000,000 ppm.

**Rejected with typed errors (tested):**
- non-positive or out-of-order segments or spans, overlaps, non-contiguous segments, a jump within an epoch
  (`discontinuityWithinEpoch`), and overlapping epoch images;
- reusing an epoch across a gap (`gapMustRestartEpoch`, `epochReusedWithinOccurrence`), uncovered placements, and
  non-monotonic placement;
- a reference epoch that is missing, not the identity, or not anchored; a misplaced `timelineReference`; an epoch
  or occurrence placed in two groups;
- a `clockApproved` map without the provisional gates. `ClockApproval` and `IndependentClockReference` have
  **no public construction path**: their initialisers are internal, the types are encode-only, and no public
  factory exists. An `ApprovalSurfaceTests` source scan enforces this. Acoustic proposals carry a distinct
  `AcousticConsistencyMeasurements` type, so acoustic evidence cannot be handed to an approval. Strict decoding
  refuses acoustic measurement keys inside an approval. Capture metadata can only seed a proposal. A future
  public approval path is planned to require an opaque, holdout-qualified WW-016 evaluator token. **Residual
  risk:** decoding a persisted `MapProvenance` can still yield `clockApproved` (gated), so WW-020 must decode
  only from its own store;
- (#177, added in the WW-016 calibration PR) a `clockApproved` epoch whose approval was issued for a different
  epoch ID or different segments. A `ClockApproval` stores its epoch ID and an exact copy of the approved
  segments. `GroupTimeMap` compilation and `EpochClockMap` decoding throw `clockApprovalBindingMismatch` on any
  difference, including an exact re-split of the same function. Editing a map therefore drops its approval.
  `ClockApprovalBindingTests` covers compile, decode and whole-timeline decode. Four mutants were all killed:
  compile guard removed, decode guard removed, segment comparison removed, and epoch comparison removed;
- maps that the arithmetic proof cannot cover (`exactArithmeticEnvelopeExceeded`); newer schema versions, unknown
  keys or kinds, and non-canonical rationals.

**Mutation check:** 37 guards were broken one at a time with `/tmp`-scripted edits and then reverted. **35 were
killed**, including:
- each bound term;
- the unsupported-inverse branches;
- public approval init, factory and `Decodable`.

Two are equivalent mutants:
- relaxing the half-open end check `uLast < u1` to `<=` still fails with `placementNotCoveredByEpochMap`, because
  the last frame finds no covering piece;
- the forward knot check is implied by the grid-inverse bound, since |p·n|, |p·n + c| ≤ d·H + |c|.

Both checks are kept explicit.

**Host and commands.** macOS 27.0.1 arm64, Swift 6.4, code at `f0102d6` (based on main `219debc`). Commands:
- `cd Packages/WaveWranglerKit && swift test --filter WWTimeMapTests` (49 tests in 11 suites, about 4.5 s);
- `scripts/test.sh`.

CI runs on macos-26 / Xcode 26.6.

**Not claimed.**
- No offset/drift *estimator* (WW-016/021), no real-recording validation, and no frozen-holdout evaluation;
  calibration on synthetic maps is not holdout evidence.
- No decoding, resampling or rendering (WW-018), and no persistence or schema migration (WW-020).
- The clock-approval gate thresholds are the provisional foundation-spike values, not tuned. Passing them is
  necessary but not sufficient for `clockApproved` (M2-C4 also requires the frozen WW-016 holdout).
- The lag sign is a *declared* convention, tested here only definitionally. Estimating the lag sign is untested and
  remains open (M2-C3).

## `m2-freeze-timemap` (calibration only)

Refs #10. [`m2-freeze-timemap.json`](../fixtures/m2-freeze-timemap.json) (2026-10-06, in the
[registry](../fixtures/m2-fixture-registry.json)) freezes fixture M2-TIMEMAP-001 with:
- 7 strata: general, multi-segment, gap, unsupported, extreme rate ratio, edge nominal rate and long occurrence;
- seeds `SHA-256("ww-m2-fixture|v1|M2-TIMEMAP-001|<split>|<index>")`, disjoint from the regression seeds above;
- 700 calibration and 2,100 holdout cases. Rule of three: zero failures in the holdout bounds the per-case failure rate
  below about 0.14 % overall and 1 % per stratum;
- the gate verbatim. Round trip within 0.5 source frame (nearest-rank p95 and max reported). Gaps are not invertible.
  Forward and inverse agree on unsupported and gap. The oracle agrees on everything;
- the pinned `WWTimeMap` (`24c7aadf…`, unchanged by this PR) and `WWTimeMapTests` tree IDs, which `TimeMapFreezeTests`
  re-checks on every run.

`RoundTripPropertyTests` now labels each failure with a category. Its regression numbers above are unchanged.

**Calibration (pre-freeze), every gate PASS, first run.** Records:
[`ww-015/calibration.jsonl`](ww-015/calibration.jsonl), SHA-256 `42bb9566…ec488a7e9e96`, byte-identical across separate processes.
- 700 cases: 3,104 occurrences, 6,248 spans, up to 185,522,597,535 frames.
- 52,887 exact frame round trips.
- 78,913 inverse round trips: quantisation **max 0.5, p95 (nearest-rank) 0.4679** source frames.
- Forward gap / unsupported / outside: 8,624 / 6,231 / 28,877. Inverse: 8,090 / 2,005 / 12,476.
- 0 failures in every category.

Same host as above. `scripts/test.sh` runs the calibration split in its own serialized pass.

**Holdout NOT RUN.** It runs once, in its own PR after this one merges, with
`WW_M2_TIMEMAP_HOLDOUT=1 swift test --filter TimeMapCalibrationTests/holdoutSplitMeetsEveryFrozenGate`.
