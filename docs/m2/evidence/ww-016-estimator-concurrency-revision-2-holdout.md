# WW-016 estimator harness revision-2 holdout

Freeze: `m2-freeze-estimator-2` (`b875d0a1ab34af35700b1246e8b497e23cc06799`), clean worktree at start. The
WWAlignEstimate source tree remained `8efd588a6b57dc56bf7eafa1ccf2c7709253f3a9`; the revised test tree matched the
committed pin `70664a686bb1b630f2a67aafdc2c0b5b7db8837e`. The pre-run consistency tests had already proved the new
140-case seed set unique and disjoint from both the original calibration and the passed M2 holdout.

**Run once:** 2026-10-08 15:51:11 -0400 on `Macatron.local`; starting load average 9.30 / 12.53 / 15.40 (1/5/15
minutes). macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4, 18 logical CPUs, 128 GiB. Command:

```sh
WW_ESTIMATOR_HOLDOUT=1 WW_ESTIMATOR_MAX_CONCURRENCY=2 WW_ESTIMATOR_CONCURRENCY_GRANT= \
  swift test --package-path Packages/WaveWranglerKit --scratch-path .build/swiftpm --jobs 4 \
  --no-parallel --filter HoldoutTests
```

Raw, unedited output: [`ww-016-estimator-holdout-revision-2.log`](ww-016-estimator-holdout-revision-2.log).
`frozenHoldout()` passed in 372.334 s; all consistency tests passed; exactly 140 cases / 170 epochs ran.

| Stratum | Cases | Epochs | Proposals | Abstentions | Clock residual p95 / max (ms) | Proposals failing clock gates |
|---|---:|---:|---:|---|---:|---:|
| positive | 40 | 40 | 40 | — | 0.9860 / 1.0052 | 0 |
| positiveRestart | 10 | 20 | 20 | — | 0.9677 / 1.0117 | 0 |
| positiveThreeGroup | 10 | 20 | 20 | — | 0.7483 / 0.8068 | 0 |
| constantDelay (35 ms) | 10 | 10 | 10 | — | 35.0078 / 35.0171 | 10 |
| variableDelay (20→50 ms) | 10 | 10 | 10 | — | 47.9593 / 49.5042 | 10 |
| discontinuity | 10 | 10 | 0 | discontinuous=10 | — | 0 |
| unrelated | 10 | 10 | 0 | weak=10 | — | 0 |
| silent | 10 | 10 | 0 | silent=10 | — | 0 |
| periodic | 10 | 10 | 0 | ambiguous=3, periodic=7 | — | 0 |
| disconnected | 10 | 10 | 0 | disconnected=10 | — | 0 |
| cycleConflict | 10 | 20 | 0 | cycleInconsistent=20 | — | 0 |

**Gate: PASS.** All 80 positive epochs were proposed; pooled independent clock-truth residual p95 was 0.9681 ms and
maximum was 1.0117 ms over 8,000 grid points. False accepts were zero. All 20 acoustic-delay cases remained labeled
`acousticConsistentProposal`; none were within the clock gates if promoted. No counts or thresholds were lowered.

This is measured local macOS 27 evidence; it does not establish or claim macOS 26 CI proof. The original
`m2-freeze-estimator` record and holdout evidence remain unchanged.
