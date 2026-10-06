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

## Holdout (post-freeze, run once)

Refs #15 #24. Freeze: `docs/m2/fixtures/m2-freeze-estimator.json` (`m2-freeze-estimator`, frozen 2026-10-06). Run
commit `602edc05b79157f56c264e1db41e8e16ab752c5e` (`main`, the freeze's own merge commit — clean checkout, `git status`
clean before the run). Pinned trees verified equal to the freeze record before running, and re-verified by
`HoldoutTests.estimatorAndHarnessTreesMatchTheFreezeRecord` during the run:
`Sources/WWAlignEstimate` `8efd588a6b57dc56bf7eafa1ccf2c7709253f3a9`,
`Tests/WWAlignEstimateTests` `b65bd478d1e2dfaa664006ba66433e0011f89dd0`. Dependency trees actually run (informational,
not pinned): `Sources/WWTimeMap` `24c7aadfbf1470c8555542061ab08eb23e37325b`, `Sources/WWCore`
`c310389c4b41ebde80c5dabaea12fd5376f5d9ba` — both equal to `dependencyTreesAtFreeze`.

Host: Apple M5 Max, 18 cores, 128 GiB, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1
clang-2100.3.34.1), debug build — same host as calibration. Command, from `Packages/WaveWranglerKit`:
`WW_ESTIMATOR_HOLDOUT=1 swift test --scratch-path .build/swiftpm --filter HoldoutTests`. `frozenHoldout()` ran
198.348 s (printed by `swift test`); wall time for the 5-test `HoldoutTests` suite (frozen-definition,
split-disjointness, registry-match, tree-match and the holdout itself) was the same, run once, not repeated. Start
time `2026-10-06T11:42:40Z` is from the shell's own `date -u +"%Y-%m-%dT%H:%M:%SZ"`, run immediately before invoking
`swift test`; `swift test` itself prints no timestamps. Master seed `0x57571600401D0000`, estimator
`ww-align-estimate/1`, 140 cases / 170 epochs — the frozen holdout counts exactly, no more and no fewer. Raw,
unedited test output, including the full build log and compiler warnings preceding the test run, captured verbatim
by piping the command through `tee`: `docs/m2/evidence/ww-016-estimator-holdout-run.log`. Every per-case line,
machine-readable: `docs/m2/evidence/ww-016-estimator-holdout-cases.jsonl` (170 records, one per epoch, parsed
verbatim from the log's per-epoch lines).

| Stratum | Cases | Epochs | Proposals | Abstentions | Clock residual p95 / max (ms) | Proposals failing clock gates |
|---|---|---|---|---|---|---|
| positive | 40 | 40 | 40 | — | 0.9695 / 0.9903 | 0 |
| positiveRestart | 10 | 20 | 20 | — | 0.9499 / 0.9592 | 0 |
| positiveThreeGroup | 10 | 20 | 20 | — | 0.9781 / 0.9883 | 0 |
| constantDelay (35 ms) | 10 | 10 | 10 | — | 35.0032 / 35.0084 | 10 |
| variableDelay (20→50 ms) | 10 | 10 | 8 | discontinuous=1, inconsistent=1 | 47.9480 / 49.3782 | 8 |
| discontinuity (±40 ms step) | 10 | 10 | 0 | discontinuous=10 | — | 0 |
| unrelated | 10 | 10 | 0 | weak=10 | — | 0 |
| silent | 10 | 10 | 0 | silent=10 | — | 0 |
| periodic | 10 | 10 | 0 | ambiguous=3, periodic=7 | — | 0 |
| disconnected | 10 | 10 | 0 | disconnected=10 | — | 0 |
| cycleConflict (mechanism) | 10 | 20 | 0 | cycleInconsistent=20 | — | 0 |

**Gate (`GateEvaluation`, the frozen definition) on the holdout: PASS.**
- Positives: 80/80 epochs proposed (an abstaining positive fails the window gate). Every positive epoch had
  ≥14/16 eligible windows (≥87.5%, above the 60% floor) and ≥86.9% overlap span (above the 80% floor); both exceed
  the ≥5-window floor. Pooled clock residual p95 0.9699 ms, max 0.9903 ms over 8,000 one-second grid points —
  both comfortably inside the 5 ms / 10 ms gate.
- False accepts: 0. Zero `clockApproved` emissions (the module has no such path). Zero proposals in any
  abstention-required stratum (discontinuity, unrelated, silent, periodic, disconnected, cycleConflict: 70/70
  epochs abstained). Zero acoustic-delay proposals mislabelled — all 18 proposed constantDelay/variableDelay
  epochs carry `acousticConsistentProposal` provenance only, and 0 of them would pass the clock gates if promoted.
- constantDelay: 10/10 proposed, clock-wrong by 35.00–35.01 ms every time (truth is a constant 35 ms propagation
  delay, not a clock error) — consistent with calibration's 35.0 ms finding.
- variableDelay: 8/10 proposed (1 abstained `discontinuous`, 1 abstained `inconsistent` — the strict consistency
  fit correctly refused a windowed delay ramp that didn't fit a single offset/drift line); the 8 proposals are
  per-epoch clock max 49.15–49.38 ms (stratum pooled p95 47.95 ms), with fitted ppm −208 to −341 against truths of
  −90 to +41 ppm, matching calibration's pattern that a slowly varying propagation delay reads to the estimator as
  drift.
- cycleConflict: all 20 epochs (10 cases × 2 epochs) measured a cycle disagreement of 20.0–20.1 ms (tolerance
  2.0 ms) and abstained `cycleInconsistent`; 4 epochs (case indices #1, #4, #5, #6) also carried a `coverageGap`
  flag with no effect on the abstention.

**This PASS qualifies the acoustic-proposal envelope only.** Per the frozen gate's authority note (verbatim in
`m2-freeze-estimator.json`), a PASS means positives proposed within the clock gates and every finite negative
either abstained or was labelled `acousticConsistentProposal` — it does **not** authorize `clockApproved`. The
module still has no `clockApproved` path (`EstimatorPurityTests` bans the approval surface), and the holdout
confirms rather than changes that: audio alone cannot separate a constant or slowly varying propagation delay from
a clock offset/drift (constantDelay and variableDelay here, same as calibration's 6/6). Under M2-C4 and the
2026-10-06 drift-fallback decision, the M2 drift fallback stays manual epochs and anchors; `clockApproved` needs
independent clock truth (externalEvidence such as supplied timecode or word clock) plus a new dated freeze and a
fresh holdout.

**Limits, same as calibration.** Synthetic, single-host evidence; no real rooms, recorders, codecs, reverberation or
moving sources. This is the only holdout run under this freeze revision — rerunning to seek a different result
would violate the freeze's `postFreezeRule` and is not done here, pass or fail.
