# WW-015 evidence: clock epochs, coordinate maps and supported inverses

**Scope.** `WWTimeMap` (Packages/WaveWranglerKit) is a pure value-type module (Foundation + WWCore only; no I/O, no
Dates/URLs/tasks, no floating point in map code — `PurityTests` enforces this). It provides occurrence → epoch spans →
group clock → positive piecewise affine segments → one aligned timeline, with an explicit `TimelineReference`
(group, epoch, occurrence). **Conventions:** `u = n/F + e`, `t = a·u + b`. All values are exact `Int128` rationals.
`ppm = 1e6·(a − 1)`, and positive ppm means the group clock runs slow, so its content lands later. Clock pitch is
`1/a`; there is no time-stretch parameter. Positive lag L means the event is L frames *later* in the target
(`b = −L/F`). The only rounding is half-up quantisation `floor(x + ½)` of an exact inverse to a source frame. Each
constructed map proves, at construction time, that its arithmetic fits (envelope: F ≤ 2^20, frames ≤ 2^40,
parameter denominators ≤ 2^40, |time| ≤ 2^31 s, a ∈ [½, 2]).
**Synthetic truth** (seed `0x57573031355f544d`, generator and oracle in test code, using `Double` only to *pick*
parameters): 1,500 timelines; 2,999 groups; 6,636 mapped and 907 unsupported epochs; 14,315 segments; 5,945
occurrences; 11,434 spans; up to 238,955,040,683 frames; |ppm| up to 1,000,000. Results:
- **Forward round trips:** 96,877 frames, all exact (frame → aligned → frame).
- **Arbitrary aligned instants:** N = 146,170 inverted. Quantisation distance from the exact inverse: **max 0.5,
  p95 (nearest-rank) 0.4664** source frames.
- **Truth classification:** 15,070 forward and 15,285 inverse probes returned `.gap`; 10,203 returned `.unsupported`;
  53,611 forward and 25,365 inverse probes returned `.outsideCoverage`. Every result matched the oracle; nothing
  was extrapolated.
- **Envelope extremes:** 2^40-frame occurrences round-trip at 15 rate ratios from −500,000 to +1,000,000 ppm.

**Rejected with typed errors (tested):**
- non-positive or out-of-order segments or spans, overlaps, non-contiguous segments, a jump within an epoch
  (`discontinuityWithinEpoch`), and overlapping epoch images;
- reusing an epoch across a gap (`gapMustRestartEpoch`, `epochReusedWithinOccurrence`), uncovered placements, and
  non-monotonic placement;
- a reference epoch that is missing, not the identity, or not anchored; a misplaced `timelineReference`; an epoch
  or occurrence placed in two groups;
- a `clockApproved` map without the provisional gates. Two cases are prevented by the types rather than by a
  runtime error: capture metadata can only seed an acoustic proposal, and an acoustic proposal can never be
  clock-approved;
- interior-piece or query overflow (`exactArithmeticEnvelopeExceeded`); newer schema versions, unknown keys or
  kinds, and non-canonical rationals.

**Mutation check:** 25 guards were broken one at a time with `/tmp`-scripted edits and then reverted. **24 were
killed.** One is an equivalent mutant: relaxing the explicit half-open end check `uLast < u1` to `<=` is still
rejected with the same `placementNotCoveredByEpochMap`, because the hull piece lookup for the last frame finds no
covering piece. The guard is retained as the early, explicit check.

**Host and commands.** macOS 27.0.1 arm64, Swift 6.4, code at `5ad6338` (based on main `109a23c`). Commands:
- `cd Packages/WaveWranglerKit && swift test --filter WWTimeMapTests` (41 tests in 9 suites, about 4.4 s);
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
