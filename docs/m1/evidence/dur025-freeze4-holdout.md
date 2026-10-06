# M1-DUR-025: two-device iCloud holdout under m1-freeze-4

> **Gate outcome: FAIL against m1-freeze-4.** The holdout ran 100/100 cases and **99 passed**. The show-conflict cell has **29/30**: case 15 did not reach its settle point within the frozen 420 s bound. Library-conflict 30/30, cross-machine-relink 20/20, recovery 20/20. The run was done once, on the released commit, and it is not re-run, supplemented or relabelled.

- **Hosts:** host A and host B (pseudonyms only, per m1-freeze-3 `hostLabels`), same Apple account (operator-attested, user grant E), iCloud Drive.
- **Data:** synthetic files only, headless on both hosts; no GUI.
- **Recipe:** registry M1-DUR-025 `recipeFreeze3` / `variantsFreeze3` (m1-freeze-3, `d55f992`, protocol §4.3), with `recipeFreeze4` (m1-freeze-4, `e70be08`, protocol §4.4): the level-sampling FAIL rule, the independent inclusion judgement, the truth-1 settle clause and the Combine summary check.
- **Reproduce at `b5f797f`**, the commit that ran. This PR's head also has later commits: evidence documents, plus one post-run harness change, `fdd9999`, which makes `cleanup()` also delete the `<split>-reserve` folder. That change is verdict-neutral and doesn't alter any recorded result.
- **Lead rulings applied:**
  - an SSH or harness error is a case FAILURE (none occurred);
  - the settle clause uses the raw listing with no exemption;
  - library cells require a completed Combine.

| Cell | Frozen holdout count | Evaluated | Pass | Fail | setupNotEstablished |
|---|---:|---:|---:|---:|---:|
| show-conflict | 30 | 30 | 29 | **1** | 0 |
| library-conflict | 30 | 30 | 30 | 0 | 0 |
| cross-machine-relink | 20 | 20 | 20 | 0 | 0 |
| recovery | 20 | 20 | 20 | 0 | 0 |

## The failure: show case 15 (simultaneous, 0 ms skew, host B triggered first)

**At the bound:**
- Both hosts acknowledged their saves locally (C3 "Saved on this Mac").
- At the 420 s bound (`timeToSettleMs` 421 806), the hosts were not byte-identical. Host A held A's publication.
- Neither host listed an unresolved conflict version, so neither host's status showed one.
- Settle not reached within the bound is a case FAILURE under the frozen recipe. The harness's path label for host B, `silentLastWriterWins`, describes the state at the bound. It is not a settled verdict.

**After the bound (read-only, no re-run):** inspect on both hosts at 01:25:01Z, about 3–7 minutes later, while the trial folder still existed. See [`holdout/case15-post-bound-observation.txt`](dur025-freeze4/holdout/case15-post-bound-observation.txt).
- A's publication was current and byte-identical on both hosts.
- B's edit was an unresolved NSFileVersion conflict version (saved by host B) on both hosts.
- The show status count was 1 on both hosts.
- So no edit was lost and the product surfaced the conflict, but iCloud took longer than the frozen bound. This doesn't change the verdict.

**Context, recorded and not used to excuse anything:**
- GUI lanes ran on host B in parallel throughout (coordinator decision); host B's load average was about 6.9 at the start.
- SSH refusals: 0. SSH retries: 0. Clock offset (B − A): 22 ms at the start and 20 ms at the end (RTT 50.5 / 48.4 ms).
- One other setup was slow. In show case 16, host B had not received the fixture after 420 s; its download request returned `NSCocoaErrorDomain 4`, and the fixture arrived 31.9 s into the retry, so setup was established.
- Provider timing is not controlled. Every latency below is as observed.

## Run record

| Field | Value |
|---|---|
| Commit | `b5f797f1f6dda763062cd7b2f1dac068ad91d32b`: harness branch `brandonmartinez/m1-dur025-freeze3` with main `e7d5ef4` merged (the coordinator's release). The tree was clean. |
| Ancestry (`git merge-base --is-ancestor`, in the run record) | `24dd627` yes, `2531a97` yes, `4a01cac` yes, `5027e19` yes, `d55f992` yes, `dc5b9ea` yes, `de3800a` yes, `e70be08` yes, `e728b94` yes, `e7d5ef4` yes |
| Trees (host A; host B runs the same probe binary) | WWPersistence `eefa0b96135602f5c10f9d47c3c3e39b44bab9f5` · WWSources `deecf3e48b4beb1debe6353e24a8154b30201208` · WWPersistenceProbe `c917f546a2a89db8703f92021b9bf757d920aca6` · scripts/dur025 `0975cc6c106b04f83e4a51cbf9271d995edd0e7d` |
| Probe | sha256 `20d73c9b1efc190d8c2f52b659b9d73c5e2cda6f418f738c3103fefb955040fd`, identical on both hosts (host B attested by this hash). |
| Host A | Mac17,14, Apple M5 Max, 18 cores, 128 GiB, macOS 27.0.1 (26A434), Xcode 27.0 Build version 27A266a, SDK 27.0, Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1) |
| Host B | Mac14,12, Apple M2 Pro, 12 cores, 32 GiB, macOS 27.0.1 (26A434), Xcode 27.0 Build version 27A266a, SDK 27.0, Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1) |
| Window | 2026-10-06T00:54:57Z → 2026-10-06T02:53:19Z, run once; 6 case workers; setup serialized |
| Seeds | `sha256("ww-m1-fixture\|v1\|M1-DUR-025\|holdout-f3\|" + caseIndex)`; reserve `holdout-f3-reserve` (not used: 0 setupNotEstablished) |
| Cleanup | `<iCloud Drive>/WaveWrangler-M1-Synthetic-Trial/dur025/holdout-f3` deleted at 2026-10-06T02:53:20Z; device-local state on both hosts deleted |

Per-case records: [`holdout/results.jsonl`](dur025-freeze4/holdout/results.jsonl). Each case records its variant, setup waits and diagnostics, first product operation, verdict, and the level samples with per-version records. Run record: [`holdout/run-record.json`](dur025-freeze4/holdout/run-record.json).

## Holdout detail (output of `scripts/dur025/summarize.py`)

| Cell | Evaluated | Pass | Fail | setupNotEstablished | Of the fails: harness error | Cell |
|---|---:|---:|---:|---:|---:|---|
| show | 30 | 29 | 1 | 0 | 0 (counted as fail) | FAIL |
| library | 30 | 30 | 0 | 0 | 0 (counted as fail) | pass |
| relink | 20 | 20 | 0 | 0 | 0 (counted as fail) | pass |
| recovery | 20 | 20 | 0 | 0 | 0 (counted as fail) | pass |

#### show
- variants: simultaneous fail ×1; simultaneous pass ×19; staggered pass ×10
- setup waits: 31 (1 after a download request); first-product-operation order OK in 30/30
- time to settle: n=30 p50 66.1 s · p95 176.6 s · max 421.8 s
- setup wait per fixture (until observed on host B): n=30 p50 45.7 s · p95 101.9 s · max 151.6 s
- detection paths: {"A": "current", "B": "providerSurfaced"} ×19; {"A": "current", "B": "appDetected"} ×10; {"A": "current", "B": "silentLastWriterWins"} ×1
- hosts with a local acknowledgement: 1 ×10, 2 ×20
- version counts per host: {"A": {"other": 1, "status": 1, "unresolvedConflict": 1}, "B": {"other": 1, "status": 1, "unresolvedConflict": 1}} ×19; {"A": {"other": 0, "status": 0, "unresolvedConflict": 0}, "B": {"other": 0, "status": 0, "unresolvedConflict": 0}} ×11
#### library
- variants: combineOnAThenB pass ×20; concurrentCombine pass ×10
- setup waits: 30 (0 after a download request); first-product-operation order OK in 30/30
- time to settle (per Combine round): n=31 p50 53.0 s · p95 109.3 s · max 175.1 s
- setup wait per fixture (until observed on host B): n=30 p50 36.3 s · p95 66.8 s · max 86.5 s
- detection paths: "providerL4" ×30
- hosts with a local acknowledgement: 2 ×30
- level samples on A: holding 155; freeze-4 FAIL samples 0; literal freeze-3 FAIL samples 53; max gap while holding 2.0 s
- level samples on B: holding 841; freeze-4 FAIL samples 0; literal freeze-3 FAIL samples 110; max gap while holding 2.1 s
- cases with literal freeze-3 FAIL samples: [(30, {'A': 0, 'B': 10}), (35, {'A': 6, 'B': 9}), (36, {'A': 6, 'B': 9}), (37, {'A': 5, 'B': 8}), (38, {'A': 6, 'B': 5}), (41, {'A': 5, 'B': 9}), (45, {'A': 7, 'B': 15}), (48, {'A': 6, 'B': 17}), (49, {'A': 6, 'B': 15}), (59, {'A': 6, 'B': 13})]
- product/harness inclusion disagreements (version samples): 12
- Combine rounds: 1 ×29, 2 ×1
- Combine summary checks: 40/40 OK
- presence of each Mac's change on each host: current ×104, copy ×16
- settle clause OK: 30/30
#### relink
- variants: moved pass ×7; replaced pass ×6; same pass ×7
- setup waits: 93 (0 after a download request); first-product-operation order OK in 20/20
- time to settle: n=0
- setup wait per fixture (until observed on host B): n=93 p50 1.3 s · p95 102.0 s · max 172.8 s
#### recovery
- variants: aKilledP4 pass ×1; aKilledP5 pass ×5; bRelaunches pass ×7; bSaves pass ×7
- setup waits: 20 (0 after a download request); first-product-operation order OK in 20/20
- time to settle: n=20 p50 12.6 s · p95 83.3 s · max 282.7 s
- setup wait per fixture (until observed on host B): n=20 p50 71.5 s · p95 126.5 s · max 270.9 s

#### Not passed: 1
- holdout-f3 #15 (show/simultaneous): fail —

**Notes on the library cell:**
- **Freeze-4 level sampling:** 0 FAIL samples on either host among the evaluable samples. The literal freeze-3 reading (ready while the raw list is non-empty), as `literalReadingReport` requires:
  - **190 samples across 23 cases** (host A 74, host B 116), counting both the in-window samples and the samples taken right after each product load (`samplesAtLoads`);
  - the summary lines above count in-window samples only (A 53, B 110 in 10 cases). All of these are versions the product had already included and both judgements proved included, during the window before iCloud dropped them from its list.
- **Unevaluable at-load samples (record honesty, verdicts unchanged):**
  - In cases 42, 55 and 58 (all combineOnAThenB), host A's sample taken right after its round-1 Combine load shows `level: ready` with 1 raw unresolved version but an **empty** per-version list.
  - The read-only load enumerated no version, so `judge_sample` evaluated nothing and scored the sample as passing.
  - Under freeze-4's "never exempt" wording, a ready sample with an unresolved version that can't be shown exempt arguably FAILS. **On that strict reading the library cell is 27/30, not 30/30.**
  - The recorded verdicts stay as the run produced them: library 30/30 on the truth-2 assertions, which the review confirmed (L4 on both hosts, all 120 presences, non-vacuous backups, converged). The gate outcome is FAIL either way.
  - **Harness gap, for #146:** the probe's `seenByLoad` (versions the read-only load saw) and `unresolvedAfterLevel` (raw count after the load) weren't kept in the per-sample records. So these three samples can't be resolved after the fact into "the version left the list between the raw read and the load" versus "the load missed it". A requalification harness must keep both fields and treat an empty enumeration with raw > 0 as unevaluable, never as a pass.
- **Product/harness inclusion disagreements:** 12 in-window version samples (11 in case 30, 1 in case 40) and 8 samples taken right after a load. In every one the product said "not included" and the independent judgement said "included", and the level was L4 (changedElsewhere), so the version was surfaced. This is the conservative direction: the product's strict inclusion doesn't count an ST-36 copy, the harness judgement does. The failing direction (product included, harness not) occurred 0 times.
- **Settle clause** (raw listing, no exemption): 30/30. The completed-Combine criterion held in all 30 cases: byte-identical on both hosts, both changes present (current ×104, copy ×16), 0 unresolved, and every resolved version backed up with exactly its bytes.
- **Combine rounds:** 1 round in 29 cases. Case 30 (concurrentCombine) needed 2, because the two concurrent Combines raced and host A was still in L4 after round 1. Combine summary checks: 40/40.
- **Ordering gate:** host B held the conflict for at least 2 samples before host A combined in every case. The maximum gap between samples while holding was 2.0 s on A and 2.1 s on B.

**Show:** in 19 simultaneous cases the race was surfaced by the provider (1/1/1 versions on both hosts). In 10 staggered cases host B detected the conflict itself: B's stale publication was stopped, its candidate preserved, and A's publication stayed current on both hosts. Case 15 is the failure above.

**Relink:** in 20 cases (same ×7, moved ×7, replaced ×6), host B had no record and needed a regrant; the explicit choice required confirmation. Host A reported moved and replaced sources correctly. Zero source writes on both hosts.

**Recovery:** 20/20 (bSaves ×7, bRelaunches ×7, aKilled P5 ×5, aKilled P4 ×1). In aKilled cases host B's checkpointed edit was still offered afterwards.

## Provider propagation across all DUR-025 runs (observations, not attribution)

Compiled from every freeze-2, freeze-3 and freeze-4 run record for Lead's remedy ruling. All times are in host A's clock, polled by the observer (so upper bounds), with nearest-rank percentiles.
- **Settle:** trigger → settle point; for library, per Combine round.
- **Setup:** A's setup publication → observed on host B, per fixture.

**Load context:**
- Freeze-2 runs (2026-10-05 18:04–19:53Z): the user-directed GUI pause was in effect, so no GUI lanes ran on either host. No load samples were recorded. The freeze-2 holdout's final clock sample had RTT 391 ms and offset 190 ms (53 ms / 24 ms at the start).
- Freeze-3/4 runs (2026-10-06 00:12–02:53Z): GUI lanes ran on host B in parallel. The only load sample is host B's load average, 6.93 / 5.29 / 4.80 at 00:54:47Z; host A's load was not recorded. SSH refusals and retries: 0. Clock offset 19–23 ms, RTT 46–54 ms.

| Run | Cell | Settle p50 / p95 / max | Over 300 s | Setup p50 / p95 / max |
|---|---|---|---:|---|
| freeze-4 holdout | show | 66.1 / 176.6 / 421.8 s | 1 | 45.7 / 101.9 / 151.6 s (case 16 excluded: about 456 s, see below) |
| freeze-4 holdout | library | 53.0 / 109.3 / 175.1 s | 0 | 36.3 / 66.8 / 86.5 s |
| freeze-4 holdout | recovery | 12.6 / 83.3 / 282.7 s | 0 | 71.5 / 126.5 / 270.9 s |
| freeze-4 holdout | relink | – | – | 1.3 / 102.0 / 172.8 s |
| calibration-f3 | show / library / recovery | max 148.4 / 88.1 / 12.7 s | 0 | max 135.0 s |
| dev-f3 attempts 2–3, drill | all | max 93.5 s | 0 | max 105.4 s |
| freeze-2 holdout | show | 86.1 / 97.5 / 98.5 s | 0 | 57.1 / 81.2 / 81.4 s |
| freeze-2 holdout | library (trigger → first settle, **before** Combine; not comparable with freeze-4's per-round values) | 101.2 / 122.5 / 122.8 s | 0 | 43.6 / 75.7 / 76.2 s |
| freeze-2 holdout | library (trigger → final settle **after** Combine, `finalSettleMs`) | 179.2 / 257.0 / 257.2 s | 0 | – |
| freeze-2 holdout | recovery | 14.8 / 56.5 / 57.0 s | 0 | – |
| freeze-2 holdout | relink | – | – | not recorded per fixture: 15 passing cases took 40–133 s in total; 5 failed cases waited out 3 × 420 s on one source (939–1016 s) |
| freeze-2 calibrations 1–3 and dev-calibration-1 | show / library (pre-Combine) / recovery | max 97.1 / 98.0 / 13.1 s; library after Combine (`finalSettleMs`) max 189.0 s | 0 | 35–81 s |
| freeze-2 dev-check (freeze-2 cells, 1 case each) | show / library (pre-Combine) / recovery | 32.7 / 45.2 / 13.0 s; library after Combine 133.7 s | 0 | 173.3–173.9 s |
| freeze-2 dev-smoke (pre-freeze-2) | all | settle not recorded | – | 85.4–87.0 s |

Library columns differ by run: freeze-4 reports each Combine round's settle (post-Combine), while freeze-2's first library row is trigger → first settle before any Combine. Use the `finalSettleMs` row to compare.

**Shared window in the freeze-4 holdout:**
- Show case 15's settle window (01:10:05Z to about 01:17:07Z; FAIL at the bound) and show case 16's setup stall (01:10:05–01:17:42Z; first wait expired at 424.6 s, fixture arrived 31.9 s into the download-request retry) cover the same ~7 minutes.
- Show case 23 (settle 177 s, from 01:24:49Z) followed shortly after.
- Outside that window, the freeze-4 show settle maximum is 119 s, and nothing exceeded 300 s in any other run.
- The freeze-2 setup stall (relink cases 61–65) occurred with the GUI paused.

These are observations only. Neither stall is attributed to a cause.

**Lead ruling (2026-10-06):**
- No freeze-5 and no further DUR-025 runs in M1, unless the user approves a changed bound.
- An environment-only revision would not address an identified cause.
- Raising the bound after seeing the failure needs the user's explicit approval.
- The freeze-4 run (99/100, FAIL) stands as recorded here.

## Before the holdout: disclosed runs (none counted)

| Run | Commit | Result | Notes |
|---|---|---|---|
| dev-f3 attempt 1 | `e9cfdc3` (pre-rebuild branch history: the branch was rebuilt on main `e70be08` as `a3d6f3e` after #128's squash merge, so `e9cfdc3` isn't an ancestor of this PR) | show pass; library falsely setupNotEstablished; relink and recovery not reached | Uncounted mechanics check (Lead ruling). SSH authentication to host B failed mid-run (1Password agent), and the run was terminated before its own cleanup. Two harness bugs were found: (1) the setup wait used the show-document `await`, so a library publication could never match; (2) an SSH-failed diagnostic was read as "absent". The trial folder was deleted at 21:39:53Z, and host B's state at 00:12:25Z, when SSH returned. |
| dev-f3 attempt 2 | `3a6acee` | 3 pass; library fail | Harness measurement bug: it read the raw NSFileVersion listing right after a product load instead of judging at the frozen sample and settle points. The case had converged with 0 freeze-4 FAILs. Fixed in `2531a97`. |
| dev-f3 attempt 3 | `24dd627` | 3 pass; library fail | Harness bug: a count-based "backup per resolved version" check. Backups are content-addressed, and one version was resolved twice in an operation, so one backup file was correct. Fixed in `4a01cac` with a per-version, exact-bytes backup check. Attempt 3 predates the settle-clause refinement `dc5b9ea`. |
| calibration-f3 | `4a01cac` | **10/10** | Labelled calibration. Covered the staggered show, the concurrentCombine library case and the host-B sampling gate. Ancestry sidecar: [`pre-holdout/calibration-f3/ancestry.json`](dur025-freeze4/pre-holdout/calibration-f3/ancestry.json). |
| drill-f3 | `4a01cac` | setupNotEstablished, then refill pass | The forced-stall drill (details below). Uncounted split. |

Harness commits after dev-f3 attempt 1 (all harness bugs or Lead rulings; none tunes truth, counts or gates): `3a6acee` (an SSH or harness error is a FAILURE), `2531a97`, `24dd627` (setup-wait durations recorded), `dc5b9ea` (settle clause on the raw listing; #119 notice only for undecodable or different-library versions; polling within the bound), `5027e19` (completed Combine in both library variants) and `4a01cac`. After calibration, `e728b94` changed reporting only: ancestry written into the run record, and library settle reported per round.

**Internal duplicate resolved entry** (not user-facing, no issue, per Lead): when an operation's Combine resolves a version that NSFileVersion still lists, a later re-detection in the same operation can resolve it again. `LibraryStore.resolvedProviderConflicts` then has a duplicate entry. The backup is the same content-addressed file, and the app never displays this list.

### Calibration detail

| Cell | Evaluated | Pass | Fail | setupNotEstablished | Of the fails: harness error | Cell |
|---|---:|---:|---:|---:|---:|---|
| show | 3 | 3 | 0 | 0 | 0 (counted as fail) | pass |
| library | 3 | 3 | 0 | 0 | 0 (counted as fail) | pass |
| relink | 2 | 2 | 0 | 0 | 0 (counted as fail) | pass |
| recovery | 2 | 2 | 0 | 0 | 0 (counted as fail) | pass |

#### show
- variants: simultaneous pass ×2; staggered pass ×1
- setup waits: 3 (0 after a download request); first-product-operation order OK in 3/3
- time to settle: n=3 p50 37.8 s · p95 148.4 s · max 148.4 s
- setup wait per fixture (until observed on host B): n=3 p50 27.7 s · p95 135.0 s · max 135.0 s
- detection paths: {"A": "current", "B": "providerSurfaced"} ×2; {"A": "current", "B": "appDetected"} ×1
- hosts with a local acknowledgement: 1 ×1, 2 ×2
- version counts per host: {"A": {"other": 1, "status": 1, "unresolvedConflict": 1}, "B": {"other": 1, "status": 1, "unresolvedConflict": 1}} ×2; {"A": {"other": 0, "status": 0, "unresolvedConflict": 0}, "B": {"other": 0, "status": 0, "unresolvedConflict": 0}} ×1
#### library
- variants: combineOnAThenB pass ×2; concurrentCombine pass ×1
- setup waits: 3 (0 after a download request); first-product-operation order OK in 3/3
- time to settle (per Combine round): n=3 p50 72.3 s · p95 88.1 s · max 88.1 s
- setup wait per fixture (until observed on host B): n=3 p50 54.0 s · p95 107.1 s · max 107.1 s
- detection paths: "providerL4" ×3
- hosts with a local acknowledgement: 2 ×3
- level samples on A: holding 14; freeze-4 FAIL samples 0; literal freeze-3 FAIL samples 5; max gap while holding 2.0 s
- level samples on B: holding 83; freeze-4 FAIL samples 0; literal freeze-3 FAIL samples 10; max gap while holding 2.2 s
- cases with literal freeze-3 FAIL samples: [(5, {'A': 5, 'B': 10})]
- product/harness inclusion disagreements (version samples): 0
- Combine rounds: 1 ×3
- Combine summary checks: 4/4 OK
- presence of each Mac's change on each host: current ×10, copy ×2
- settle clause OK: 3/3
#### relink
- variants: moved pass ×1; same pass ×1
- setup waits: 9 (0 after a download request); first-product-operation order OK in 2/2
- time to settle: n=0
- setup wait per fixture (until observed on host B): n=9 p50 1.3 s · p95 41.4 s · max 41.4 s
#### recovery
- variants: bRelaunches pass ×1; bSaves pass ×1
- setup waits: 2 (0 after a download request); first-product-operation order OK in 2/2
- time to settle: n=2 p50 12.6 s · p95 12.7 s · max 12.7 s
- setup wait per fixture (until observed on host B): n=2 p50 30.9 s · p95 48.0 s · max 48.0 s

#### Not passed: 0

### Drill detail

- A synthetic source named `source-2.wav.nosync`, which iCloud Drive doesn't sync, was readable on host A with the expected digest; its upload status was "not ubiquitous".
- Host B waited 420 s, then its download request returned `NSCocoaErrorDomain 4`, then it waited another 420 s.
- Diagnostics on both hosts: absent on B; present with the expected digest on A.
- The case became setupNotEstablished and was refilled from `drill-f3-reserve` #0, which passed. Zero source writes.

| Cell | Evaluated | Pass | Fail | setupNotEstablished | Of the fails: harness error | Cell |
|---|---:|---:|---:|---:|---:|---|
| show | 0 | 0 | 0 | 0 | 0 (counted as fail) | - |
| library | 0 | 0 | 0 | 0 | 0 (counted as fail) | - |
| relink | 1 | 1 | 0 | 1 | 0 (counted as fail) | pass |
| recovery | 0 | 0 | 0 | 0 | 0 (counted as fail) | - |

#### relink
- variants: same pass ×1; same setupNotEstablished ×1
- reserve refills: slot 0 ← drill-f3-reserve #0 (pass)
- setup waits: 8 (1 after a download request); first-product-operation order OK in 2/2
- time to settle: n=0
- setup wait per fixture (until observed on host B): n=6 p50 1.3 s · p95 105.4 s · max 105.4 s

#### Not passed: 1
- drill-f3 #0 (relink/same): setupNotEstablished — fixture has not arrived on host B [stalled fixture: source-2]

## Limits

- iCloud Drive with two Macs on one Apple account only. No OneDrive/Dropbox, offline or power-loss coverage, and **no provider-atomicity claim**. Neither host is the macOS 26 / 16 GB reference.
- The harness is unsandboxed: the regrant is an explicit harness-supplied choice, not the powerbox panel.
- Sync timing is not controlled. Every latency is observed with polling, so each is an upper bound. Case 15 shows that iCloud delivery can exceed the frozen 420 s settle bound under these conditions, with GUI lanes running on host B.
- No cross-device recovery is claimed (truth 6).

## Redaction note (2026-10-06)

Records were written with paths redacted at write time (`<home>`, `<iCloud Drive>`). One committed file needed an additional redaction: `pre-holdout/dev-f3-attempt1/results.jsonl` captured SSH stderr containing host B's `user@address`. That one string, `<user>@<address>`, was replaced with `<user>@<host B>` by exact-string replacement; nothing else changed. Every line is valid JSON, and the parsed records equal the original records with only that string replaced. Pre-redaction sha256: `73b491bc117528241e49a2a0dd7679d705bbde22c931a23685a5651daaa1c120`. Correction: the first redaction (in `2ba35d1`) used a pattern that also consumed the `n` of a preceding `\n` escape, which made line 2 invalid JSON. Fixed in review. The committed evidence contains no home path, user@host string, LAN address or computer name.

## Final cleanup (grants C and E; 2026-10-06)

**Cleanup gap (harness defect):** `cleanup()` deleted only the run's split folder, so the drill's reserve refill (`drill-f3-reserve`, one synthetic show plus three synthetic sources) remained in the trial folder on both hosts. The calibration and holdout reserves were never used, so they created no folders. Fixed in this PR: `cleanup()` now also deletes `<split>-reserve`. The fix doesn't affect any recorded verdict.

**Final deletion of the `WaveWrangler-M1-Synthetic-Trial` folder, after the M1 DUR-025 work ended:**
- **Before (03:06:24–25Z):** both hosts listed only the `drill-f3-reserve` synthetic files under `dur025/`.
- **Deleted:** the whole `WaveWrangler-M1-Synthetic-Trial` folder on host A at 2026-10-06T03:06:31Z and on host B at 2026-10-06T03:06:31Z.
- **Verified after a 120 s iCloud sync wait:** absent on host A (03:08:31Z) and on host B (03:08:32Z). Neither host's iCloud Drive lists the folder.
- **Elsewhere:** host B's probe builds and device-local state for all runs were already deleted; host A's device-local state lives under the untracked `.build/` only.

