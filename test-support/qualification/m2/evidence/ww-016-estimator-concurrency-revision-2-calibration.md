# WW-016 revised test-harness calibration

Pre-freeze tuning evidence for `m2-freeze-estimator-2`. These runs used the unchanged 37-case/43-epoch calibration
split and do not count as the revision-2 holdout. The original `m2-freeze-estimator` record, source tree, passed
holdout, and evidence were not changed.

## Compute cap

| Run | Start | Host / start load average (1/5/15 min) | Limit | Helper CPU observed | Result |
|---|---|---|---:|---:|---|
| Eligible measurement | 2026-10-08 15:36:52 -0400 | `Macatron.local`, 14.24 / 17.98 / 18.73 | 2 cases | 196.7% | PASS, 101.569 s |
| Repeat | 2026-10-08 15:39:48 -0400 | `Macatron.local`, 14.46 / 17.28 / 18.35 | 2 cases | — | PASS, 102.387 s |

The helper CPU value is an in-run process sample, not a claimed peak. It is below the ≤400% acceptance threshold;
the two-slot scheduler is deterministic and never admits a third case. The host had 18 logical CPUs, macOS 27.0.1
(26A434), and Xcode 27.0 (27A266a). A later exploratory repeat started below the load ceiling but overlapped a
separate worktree render; that run is not used as the eligible-load measurement.

## Calibration result

Both completed runs reproduced the frozen calibration output exactly:

- 37 cases / 43 epochs; 20/20 positive epochs proposed.
- Pooled independent clock-truth residual: nearest-rank p95 0.9659 ms; maximum 0.9767 ms over 2,060 grid points.
- False accepts: 0. Acoustic-delay proposals: 6/6 labeled `acousticConsistentProposal`; 0 meet clock gates if promoted.
- Per-stratum p95/max, abstentions, and per-case results are in the raw run log and match
  [the original frozen calibration evidence](ww-016-estimator-calibration.md).

Raw run output: [`ww-016-estimator-concurrency-revision-2-calibration.log`](ww-016-estimator-concurrency-revision-2-calibration.log).
