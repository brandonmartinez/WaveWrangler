# WW-016/WW-021 part 1: WWAlignEstimate calibration (synthetic, pre-freeze)

Refs #15 #24 (context #11). Host: Apple M5 Max, 18 cores, 128 GiB, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a),
Swift 6.4, debug build. Code measured: the PR that adds this note (`brandonmartinez/ww-016-estimator-calibration`;
SHA in the PR), estimator `ww-align-estimate/1`. **This is calibration only; the holdout has NOT run.** The
frozen definition is `docs/m2/fixtures/m2-freeze-estimator.json`, the registry is
`docs/m2/fixtures/m2-fixture-registry.json`, and the holdout runs once in a separate follow-up PR. Command,
from `Packages/WaveWranglerKit`: `WW_ESTIMATOR_TESTS=1 swift test --scratch-path .build/swiftpm --filter CalibrationTests`
(52.0 s; `scripts/test.sh` runs it, with the scenario suite, in a serialized estimator pass), master seed `0x57571600CA11B000`. That seed gives 37 cases and 43 epochs, generated in memory by
`SyntheticGenerator`. Each case has a reference at 8 kHz for 126 s and targets at 8 or 16 kHz for 120 s.
Clock truth is ppm −100…100 and offset −1.5…1.5 s, and the truth is drawn independently of the estimator.
Residuals are |proposal(u) − clock truth(u)| on a 1 s grid over the declared overlap, and are **never** measured
against the fitted map. p95 is nearest-rank.

| Stratum | Cases | Epochs | Proposals | Abstentions | Clock residual p95 / max (ms) | Clock-wrong proposals (outside gates) | False accepts |
|---|---|---|---|---|---|---|---|
| positive | 12 | 12 | 12 | — | 0.9694 / 0.9767 | 0 | — |
| positiveRestart | 2 | 4 | 4 | — | 0.9596 / 0.9624 | 0 | — |
| positiveThreeGroup | 2 | 4 | 4 | — | 0.9016 / 0.9051 | 0 | — |
| constantDelay (35 ms) | 3 | 3 | 3 | — | 35.0078 / 35.0107 | 3 | 0 |
| variableDelay (20→50 ms) | 3 | 3 | 3 | — | 47.9634 / 49.3176 | 3 | 0 |
| discontinuity (±40 ms step) | 3 | 3 | 0 | discontinuous 3 | — | 0 | 0 |
| unrelated | 3 | 3 | 0 | weak 3 | — | 0 | 0 |
| silent | 2 | 2 | 0 | silent 2 | — | 0 | 0 |
| periodic | 3 | 3 | 0 | ambiguous 3 | — | 0 | 0 |
| disconnected | 2 | 2 | 0 | disconnected 2 | — | 0 | 0 |
| cycleConflict (mechanism) | 2 | 4 | 0 | cycleInconsistent 4 | — | 0 | 0 |

**Gate (`GateEvaluation`, the frozen definition) on calibration: PASS.**
- Positives: 20/20 epochs proposed, each with ≥15/16 eligible windows spanning ≥0.935 of the overlap.
- Pooled clock residual: p95 0.9659 ms, max 0.9767 ms over 2,060 grid points. This is mostly the generator's 0–1 ms
  constant acoustic path, which audio cannot separate from offset.
- False accepts: 0 in every stratum (0 clockApproved, 0 proposals where abstention was required, 0 mislabelled).
- Positive-epoch ppm error ≤0.75; the 3-group cycles close within 0.05 ms.

**The acoustic-delay negatives are not "cured", and the estimator never approves clocks.** All 6 acoustic-delay
epochs are proposed, and they are acoustically excellent:
- constantDelay: acoustic p95 0.01–0.06 ms and ppm within 0.2 of truth, yet every proposal is 35.0 ms clock-wrong.
- variableDelay: acoustic p95 0.32–0.48 ms and peak 0.76–0.83, yet every proposal is 49.2–49.3 ms clock-wrong, with
  a fitted ppm of −283 to −342 against a truth of −34 to −92.

No threshold separates them from positives, because a propagation delay that is constant or varies slowly with
time *is* an offset or drift as far as the audio is concerned. The audio carries no independent clock evidence:
the 3-group cycle check catches *inconsistent* pairwise solutions (cycleConflict: 20.07 ms disagreement, 4/4
abstain), but it cannot see a delay common to every path. The module therefore returns only
`acousticConsistentProposal` (a WWTimeMap segment with `AcousticConsistencyProposal` provenance) or a typed
abstention whose map is unsupported. It has no `clockApproved` path, the `ClockApproval` initialisers stay
internal, and `EstimatorPurityTests` bans the approval surface. Under M2-C4 and the 2026-10-06 drift-fallback decision, the
M2 drift fallback stays manual epochs and anchors. A holdout PASS under this freeze would qualify proposals and
abstentions only. `clockApproved` needs independent clock truth plus a new freeze; under M2-C4, user anchors are
`manual` and supplied timecode or word clock is `externalEvidence`, so neither is a route to `clockApproved`.

**Mutation checks (each guard broken, failing test observed, guard restored).**
- #177 binding, 4 mutants killed: the compile guard, the decode guard, the segment comparison and the epoch comparison.
- Estimator, 11 mutants killed: strict fit, ambiguity, periodicity, weak-peak, silence, edge extension,
  eligible-count, eligible-fraction, span, drift guard and cycle abstention.
- Gate and freeze, 15 mutants killed (G1–G15):
  - every false-accept class, abstaining positive, pooled p95 and max, window count, and acoustic mislabel;
  - holdout seed overlapping calibration, frozen counts, a frozen estimator parameter, any edit in the pinned test
    tree, a registry split, the freeze seed, a freeze gate value, and the freeze's pinned-tree record.
- Frozen identity and purity, 16 mutants killed (R1–R4 and 12 token drops):
  - the identifier stamp ignoring parameters, the report or the proposal stamped frozen under custom parameters,
    and a public parameter setter;
  - dropping each of `contentsOf`, `contentsOfFile`, `URLSession`, `NSData`, `Process(` and `Bundle` from the
    WWAlignEstimate and WWTimeMap purity scans.
- Only the frozen default parameters are stamped `ww-align-estimate/1`. Parameter setters are internal, so the public
  API can only run the defaults. In-module variants are stamped `ww-align-estimate/1+custom`.

**Throughput** (`estimatorThroughputBenchmark`, `WW_TIMING_TESTS=1` serialized pass of `scripts/test.sh`, debug build):
1,780 s of 48 kHz audio (a reference plus 2 tracks, 10 min) estimated in 75.3 s, about 24× real time. Report only; there is no throughput gate.

**Limits.**
- Synthetic, single-host evidence. No real rooms, recorders, codecs, reverberation or moving sources.
- The search range is supplied per request, and a ±2 s search means large FFTs.
- An inverted-polarity microphone abstains, because the estimator requires a positive peak.
- The strict consistency fit may over-abstain on real material.
- Cycle checks need ≥5 shared pair windows.
- The silence floor is a centred RMS of 1e-4.
- Calibration and the scenario suite are CPU-heavy (debug build; calibration 52 s on this host). They run only in the serialized estimator pass,
  because in the parallel pass they starved other suites' liveness waits on the CI runner.
- Under the frozen window rule, an abstaining positive fails the gate, so positive yield is gated as well as residuals.
