# M1 durability holdout (WW-005 / WW-049 / WW-006)

Post-freeze holdout executions at the frozen counts of registry **m1-freeze-1**
(`docs/m1/fixtures/m1-fixture-registry.json`, protocol `docs/m1/ww-003-fixture-protocol.md`).
Owner: persistence lane (Mac). The raw per-case results are committed next to this file:

- [`durability-holdout/package-results.jsonl`](durability-holdout/package-results.jsonl): package, timing and iCloud passes. Each line is one family or cell, with an outcome code for every case.
- [`durability-holdout/native-results.jsonl`](durability-holdout/native-results.jsonl): NSDocument / app passes.
- [`durability-holdout/run-records.json`](durability-holdout/run-records.json): commit, host and tree IDs for each pass.

**Result: 7,190 holdout cases executed, 7,190 passed, 0 failures. Every family reached its frozen count. The two items under
[Not run / short](#not-run--short) are outside the frozen counts.**

## Run record

| Field | Value |
|---|---|
| Commit | `cd1c0f10f40fe5a55bdd70d2684bdb7602740b5f` (clean tree; contains the m1-freeze-1 merge `2fcf4d7`, PR #62) |
| Split | `holdout`, run once on this frozen revision; every case is reported |
| Passes (2026-10-05 UTC) | package 07:41:22Z; timing (serialized, `WW_TIMING_TESTS=1`) 07:43:37Z; iCloud 07:45:49Z; native 07:50:36Z |
| Host | Apple M5 Max, 18 cores, 128 GiB; macOS 27.0.1 (26A434); Xcode 27.0 (27A266a); Swift 6.4 |
| Runner | Four separate invocations, one run record each (each refuses a dirty tree or a commit without `2fcf4d7`): `scripts/holdout.sh --split holdout --package` (07:41:22Z); `scripts/holdout.sh --split holdout --timing` (07:43:37Z); `scripts/holdout.sh --split holdout --icloud` (07:45:49Z); `scripts/holdout.sh --split holdout --native` (07:50:36Z) |
| Seeds | `sha256("ww-m1-fixture|v1|" + fixtureId + "|holdout|" + caseIndex)`, first 8 bytes big-endian, per cell (for example `M1-DUR-006/publisher/P3`) |

Test tree IDs (identical in all four run records):

| Tree | ID |
|---|---|
| `Packages/WaveWranglerKit/Tests/WWPersistenceTests` | `0028d4c35966c06e35bf04cee306763246223ddf` |
| `Packages/WaveWranglerKit/Sources/WWPersistence` | `e9d88eeaf586ec449163a81b91771a0362f6f007` |
| `Packages/WaveWranglerKit/Sources/WWPersistenceProbe` | `6387033820fbd419490a7a3581441bc9928bffdb` |
| `Packages/WaveWranglerKit/Sources/WWOrganizer` | `e1e370336a48d988aa963700878e94849f0e2c29` |
| `Packages/WaveWranglerKit/Sources/WWCore` | `b36189e5c3c6343d9e52937dd83884c6a8950b0b` |
| `WaveWrangler/Document` | `9e8c2460f558f096382bfdab3e31b0bc88236c49` |
| `WaveWranglerTests` | `7e1d35b09de7b68ec61289a4c75ba7e50837c301` |
| `WaveWranglerUITests` | `d24d20620b51b9e9b112c318c827f4c61107d011` |
| `scripts/holdout.sh` | `981995a995b52ceef04d7ff3922d9b74e66280c5` |

The native cells (NSDocument DUR-006 and DUR-008) ran in the sandboxed Debug app, launched directly with
`-WWUITestHooks YES -WWNativeHoldout holdout`, under the GUI lock the coordinator granted for this run. The runner,
`WaveWrangler/Document/NativeHoldoutRunner.swift`, is compiled only in `#if DEBUG`; Release ignores the hooks.

## Per-family results

Unless a row says otherwise, the label is **simulated/local, not provider-observed**. Times are in seconds.

| Family | Frozen | Achieved | Pass | Outcome mix (holdout) | p95 / max |
|---|---:|---:|---:|---|---|
| DUR-001 explicit Save | 100 | 100 | 100 | saved 100 | — |
| DUR-002 ON checkpoint timing | 100 | 100 | 100 | published revision 100 (serialized pass) | **p95 1.025 / max 1.053** (p50 1.005), each **understated by up to 0.030** (see note); provisional gate p95 ≤ 2 s met even with +0.030 |
| DUR-003 OFF no auto-publish | 100 | 100 | 100 | not published 100 | — |
| DUR-004 toggle interleavings | 100 | 100 | 100 | published before OFF 18, skipped after OFF 32, published after ON 50 | OFF→ON publish p95 1.084 / max 1.102 (n = 50) |
| DUR-005 Save while OFF | 100 | 100 | 100 | saved 100 | — |
| DUR-006 publisher P1–P7 | 700 | 700 | 700 | In-place publication (cases labelled `save` and `autosave`, see note) and Save As, spread per cell. P1–P3 old (Save As: absent); P4 old or recovered-old (Save As: absent or destination refused); P5–P6 new; P7 new | — |
| DUR-006 NSDocument P1–P3, P5–P7 | 600 | 600 | 600 | `.saveOperation` / `.autosaveInPlaceOperation` / `.saveAsOperation`. P1–P3 old, failure retained; P5–P6 new, **acknowledgement uncertain**; P7 new and verified, library acknowledgement requested once, library never claims an unverified publication (see note: persisted acknowledgement and index rebuild not asserted) | — |
| DUR-007 external-writer conflict | 100 | 100 | 100 | other revision 50, other document 50; conflict raised, both preserved | — |
| DUR-008 concurrent windows (native) | 100 | 100 | 100 | two NSDocument windows on one show, 1–9 interleaved saves per case; no lost or mixed revision | — |
| DUR-009 two-process | 100 | 100 | 100 | one saved + one conflict, 100 | — |
| DUR-010 offline destination | 100 | 100 | 100 | folder offline / path unresolvable → missing; read-only folder / file permission → permission denied (25 each) | — |
| DUR-011 cancel at stages | 100 | 100 | 100 | Save and Save As × cancelled-before-publish / saved-follow-up-incomplete (25 each) | — |
| DUR-012 retry | 100 | 100 | 100 | retried after P1 34 / P3 33 / P4 33 faults | — |
| DUR-013 ENOSPC (injected) | 100 | 100 | 100 | stage write / prior retention / publication / edit checkpoint (25 each) | — |
| DUR-014 Save As | 100 | 100 | 100 | success 34 (same show ID, new location), cancel 33, failure at P3 17 / P4 16; original intact in all | — |
| DUR-015 ack-uncertain | 100 | 100 | 100 | stale read-back 34, read-back error 33, library ack failure 33 | — |
| DUR-016 migration | 100 | 100 | 100 | plain 34, cancel → retry 33, fault → retry 33 | — |
| DUR-017 corrupt show | 100 | 100 | 100 | 7 corruption kinds (incl. duplicate key and wrong document ID), all refused | — |
| DUR-018 unknown-newer show | 100 | 100 | 100 | 6/6 mutating operations refused, for valid payloads 50 and partially unknown payloads 50 | — |
| DUR-019 library↔project reconciliation | 200 | 200 | 200 | 2 strata × 100; library acknowledges old before L5, new at L5–L6 | — |
| DUR-020 index delete/rebuild | 100 | 100 | 100 | delete / corrupt / stale / replace with other library (25 each); zero semantic loss | — |
| DUR-021 process kill (show) | 700 | 700 | 700 | SIGKILL at P1–P4 → old; P5–P6 → new; P7 → new + acknowledged | — |
| DUR-022 unknown-newer library | 200 | 200 | 200 | 2 strata × 100; 4/4 writes refused, show still openable | — |
| DUR-023 corrupt library + prior | 200 | 200 | 200 | 2 strata × 100; 7 corruption kinds, prior recovered | — |
| DUR-024 iCloud (grant C) | 290 | 290 | 290 | see [DUR-024](#dur-024-icloud-drive-grant-c) | save/autosave 1.026 / 1.044; reopen after evict 0.584 / 0.834 |
| DUR-027 injected library boundaries | 1,200 | 1,200 | 1,200 | L1–L6 × {app container, user-chosen folder} × 100; L1–L3 old, L4 old or recovered-old, L5–L6 new | — |
| DUR-028 process kill (library) | 600 | 600 | 600 | SIGKILL at L1–L4 → old; L5–L6 → new | — |
| DUR-029 reopen after relaunch + Save | 100 | 100 | 100 | saved: normal 17, stale bookmark 17, library in user folder 16. Relink required: moved 17. Regrant required: revoked bookmark 17, revoked permission 16 | — |
| SCALE-001 model level | 600 | 600 | 600 | first-open 100, warm-open 100, 400 interactions (filter, rename, select, toggle collection × 100) | first-open 0.0027 / 0.0029; warm 0.0028 / 0.0029; interactions 0.0024 / 0.0026 |

DUR-006 total = 700 publisher + 600 NSDocument = **1,300**.

What each case asserts:
- **Label notes (narrowed after review; the run stands as executed):**
  - DUR-006 publisher `autosave` cases run the same `.inPlace` publication as `save`; they do not exercise an autosave path. The autosave path is evidenced only by the native cells (`.autosaveInPlaceOperation`).
  - DUR-006 NSDocument P7 (`save:new:ackedIndexRebuilt`) asserts: the save is verified (`new` at revision 3, status verified on disk); the library acknowledgement closure ran exactly once; on reload, the library's claim for the show is either absent or the on-disk publication; and, if a library loaded, its index equals a rebuild. It does **not** assert that the acknowledgement persisted (a `nil` claim passes) or that an index was rebuilt in every case. Read the outcome code as "saved, acknowledgement requested, no false claim".
  - DUR-024 two-process conflicts: see the DUR-024 table; "both preserved" applies only to the 40 two-instance cases.
  - DUR-002: the clock started after the trailing 0–30 ms jitter sleep that follows the last edit, so each latency is understated by up to 30 ms. Worst case p95 ≤ 1.055 s and max ≤ 1.083 s; the ≤ 2 s gate is met. The timestamp was moved to the last edit for future runs (after this holdout; the seeded sequence is unchanged).
- **Boundary and kill families** (DUR-006, 021, 027, 028): after recovery in a fresh process or store, the document is either the old valid revision or the complete new revision. It is never mixed and never zero valid. The recovery store holds a validated prior, the library never acknowledges a publication that is not on disk, and the derived index equals a rebuild from the library.
- **DUR-006 publisher**: additionally records every write target and asserts zero writes under the synthetic sources folder and unchanged source digests. The other families do not repeat this per case; the structural zero-source-writes audit is `FaultInjectionHarnessTests` (outside this holdout).

### DUR-024 iCloud Drive (grant C)

Labelled **provider-observed on this Mac only (iCloud Drive, single device)**. Run as an opt-in test (`WW_ICLOUD_TRIAL=1`) in
`~/Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial/persistence/`, with synthetic data only.

| Cell | Count | Result |
|---|---:|---|
| save / autosave | 100 | explicit Save 50, autosave published 50; p95 1.026 s, max 1.044 s |
| conflict | 100 | 60 two-process: conflict detected (one `saved` + one `conflict` result, canonical file a whole valid revision); preserved candidate and on-disk winner **not checked**. 40 two-instance: conflict detected, winner on disk and loser's candidate preserved. Provider conflict versions 0 |
| evict / download | 50 | upload confirmed within 3 s (28), 4 s (19), 5 s (2), 7 s (1), evicted (`notDownloaded`), reopen p95 0.584 s / max 0.834 s, status current afterwards |
| recovery | 20 | interrupted at P3/P4 → old, P5/P6 → new (5 each) |
| library moves | 20 | move in 1, publications 18, move out 1 |

Cleanup: the `persistence/` subfolder was recreated at the start and **deleted at the end** (result line
`cleanup: persistenceSubfolderDeleted`). After the run, the trial root contained only `sources/`, which belongs to the source
lane's trial and was left untouched.

## Not run / short

| Item | Status | Reason |
|---|---|---|
| DUR-013 real-volume ENOSPC variant | **Not run** | Consent-blocked, not granted. Only the injected ENOSPC variant (100) is counted. |
| DUR-021 NSDocument random-kill set | **Not run** | The registry reports it separately and not per boundary; it is outside the frozen 700. The publisher-path 700 is complete. |
| NSDocument P4 | Not applicable (by definition) | Per registry `nsdocumentPathCoverage`, P4 (inside AppKit's safe replace) is evidenced only at the publisher level (DUR-006 publisher P4, DUR-021 P4). The NSDocument claim for P4 is limited to "AppKit stock safe-save, not independently interrupted". |

No frozen count was lowered.

## Limits

- Everything except DUR-024 is simulated/local, on APFS temp directories. It is **not provider-observed**, and no provider atomicity is claimed.
- DUR-024 is iCloud Drive on one Mac. There were 0 provider-side (`NSFileVersion`) conflict versions, so provider conflict handling across devices is not evidenced.
- Bookmarks in the package and probe passes are app-scoped but unsandboxed, so no sandbox extension is involved. DUR-029 "revoked" is simulated (bookmark data invalidated or folder permission removed). Read-only source scopes are not evidenced here.
- DUR-008 edits are programmatic; per-window focus and selection are not evidenced.
- SCALE-001 is model level (WWOrganizer/WWPersistence) and reported separately from native timings. First-open runs with a warm OS file cache, and zero main-thread I/O is not evidenced.
- Process-kill families use SIGKILL at instrumented boundaries in an owned helper (`wwpersist-probe`). They are not power-loss tests.

## Disclosures

**Product fixes made during calibration, before the holdout.** All were landed at or before cd1c0f1. The holdout split ran once,
on that commit only.
- Strict JSON: duplicate keys and malformed JSON are refused (`StrictJSON.swift`). Previously `JSONDecoder` silently kept one duplicate.
- Identity: a different library (real `libraryID`) at this library's location is refused as damaged, not loaded as this one. A different show at a show's location is refused as `identityMismatch`.
- `ShowDocument`: when the save reported an error but the candidate bytes are on disk, the status is acknowledgement uncertain, not failed.
- Device-local show reopen (`ShowLocationStore`): read-write document bookmarks, refreshed only after identity is confirmed. This adds the DUR-029 path.
- Probe: the SIGKILL self-kill is followed by a `pause()` loop (the kill raced `_exit`); P7 and library kill points; `reopen-save`.

**Calibration.** Development used the calibration split only, at the registry's calibration counts. The final calibration run
(package + native) had 0 failures.

**After the holdout (not part of the evidence).** These changes were made in the same PR, after cd1c0f1:
- #82: the `MultiProcessTests` process-kill check counts a kill only when the helper exits on signal 9 **and** its fsynced boundary marker matches. An external kill is retried with a fresh fixture.
  - The probe's `--marker` flag is optional and off by default, so the holdout's probe invocations behave as they did.
- `LibraryLoadOutcome.unavailableShowingPrior` documentation and `isReadOnly` now match L2/L3 queueing.
- DUR-004 test: the two timestamps are now shared through a Sendable `LockedBox` instead of a captured `Mutex`, because CI's macOS 26 toolchain rejects the capture. The semantics are unchanged, and the test tree ID now differs from the holdout record above.

The full `scripts/test.sh` suite ran 20 times consecutively on 7bc4a7d (before the DUR-004 `LockedBox` change, which then passed CI):
- 19 runs passed. Every run passed `processKillAtBoundary` (#82), with 0 external-kill retries.
- 1 run failed in the source lane's `WW-006 lifecycle matrix` (M1-REF-015 holdout case 3, residency/transfer timing). That test is from main and is not touched here; it was reported to the coordinator.
