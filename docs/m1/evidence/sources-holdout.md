# M1 sources lane: post-freeze holdout evidence (`m1-freeze-1`)

**Lane:** Mac (sources). **Date:** 2026-10-05. **Freeze:** [`m1-freeze-1`](../ww-003-fixture-protocol.md#41-freeze-record-m1-freeze-1-2026-10-05), which takes effect at the PR #62 merge `2fcf4d7`. **Registry:** [`m1-fixture-registry.json`](../fixtures/m1-fixture-registry.json).

Only Runs A, B and D under "Post-freeze holdout runs" count as holdout. Run C is harness and model-operation evidence, **not** holdout (see below). Each holdout run ran once, on a clean checkout of a commit that contains `2fcf4d7`. Every case is reported in the per-case files in [`sources-holdout/`](sources-holdout/), including failures and exclusions (there were none). The pre-freeze runs from #54/#58 and the calibration runs on this branch before the merge are calibration only, and are listed separately below.

## Host

| Item | Value |
| --- | --- |
| OS | macOS 27.0.1 (26A434), arm64 |
| Toolchain | Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1) |
| Hardware | 18 cores, 128 GiB (137,438,953,472 bytes) |
| Note | The claimed internal host, **not** the macOS 26 / 16 GB reference. Tests run unsandboxed (`swift test`), so security-scoped behavior is labelled non-sandboxed. |

## Post-freeze holdout runs

### Run A: lifecycle matrix (M1-REF-001…017, M1-SRC-OFF-001, M1-SRC-ON-001/002, M1-SRC-ON-002-REVIEW)

| Field | Value |
| --- | --- |
| Commit | `2f7594dbb9b212c4140b2df90146470b8e89b5f2` (contains `2fcf4d7`; clean tree) |
| Test tree `Packages/WaveWranglerKit/Tests/WWSourcesTests` | `c70d6a5febaf5cd80bbd30b44b6371b0e61a27ac` |
| Code under test `Packages/WaveWranglerKit/Sources/WWSources` | `234a3b2d77dfcf8573cda5ed384d291049c4518e` |
| Code under test `Packages/WaveWranglerKit/Sources/WWCore` | `b36189e5c3c6343d9e52937dd83884c6a8950b0b` |
| Command | `swift test --package-path Packages/WaveWranglerKit --jobs 4 --filter LifecycleMatrixTests` |
| Time | 2026-10-05T07:19:43Z, exit 0, 12.2 s |
| Every case | [`sources-holdout/lifecycle-matrix-cases.csv`](sources-holdout/lifecycle-matrix-cases.csv): 1,920 rows (1,710 holdout and 210 calibration), with seed, result, scopes, writes, substitutions, requests and provenance |

| Family | Frozen holdout | Executed holdout | Passed | Failed / excluded | Provenance |
| --- | ---: | ---: | ---: | ---: | --- |
| M1-REF-001 … M1-REF-010 (each) | 60 | 60 | 60 | 0 / 0 | observed (temp-dir file system) |
| M1-REF-011 … M1-REF-015 (each) | 60 | 60 | 60 | 0 / 0 | simulated provider double |
| M1-REF-016 | 150 | 150 | 150 | 0 / 0 | mixed: 51 simulated, 109 observed (holdout + calibration) |
| M1-REF-017 | 60 | 60 | 60 | 0 / 0 | observed |
| **Reference subtotal (REF-001…017)** | **1,110** | **1,110** | **1,110** | 0 / 0 | WW-006 gate ≥1,000: **met** |
| M1-SRC-OFF-001 (default-OFF metadata set) | 200 | 200 | 200 | 0 / 0 | simulated |
| M1-SRC-ON-001 (default-ON synthetic double) | 200 | 200 | 200 | 0 / 0 | simulated |
| M1-SRC-ON-002 | 100 | 100 | 100 | 0 / 0 | simulated |
| M1-SRC-ON-002-REVIEW | 100 | 100 | 100 | 0 / 0 | simulated |
| **Total** | **1,710** | **1,710** | **1,710** | 0 / 0 | |

Invariants across all 1,920 cases, including M1-REF-018 (an invariant, not extra cases):

| Invariant | Result |
| --- | --- |
| Leaked security scopes (ledger open count, start/stop parity, gateway per-URL count) | **0** |
| Source writes (harness bytes + mtime + inode + mode of every generated file, before vs after every app phase) | **0** |
| Silent substitutions | **0** |
| OFF-path download and progress requests (M1-SRC-OFF-001) | **0** |
| Content, hash, header, preview or decode requests | 0 **by construction**: `SourceIO` has no such API and a source scan forbids it. This is not a measured counter. |

The 10 calibration cases per family (210 in total) ran in the same invocation with disjoint calibration seeds. They all passed, are reported separately here, and tuned nothing.

### Run B: M1-SRC-ON-PROV-001, iCloud Drive (grant C)

| Field | Value |
| --- | --- |
| Commit | `2f7594dbb9b212c4140b2df90146470b8e89b5f2` (clean tree) |
| Test tree `WWSourcesTests` | `c70d6a5febaf5cd80bbd30b44b6371b0e61a27ac` |
| Code under test `WWSources` | `234a3b2d77dfcf8573cda5ed384d291049c4518e` |
| Command | `WW_ICLOUD_TRIAL=1 WW_ICLOUD_HOLDOUT=1 swift test … --filter frozenHoldoutCycles` |
| Time | 2026-10-05T07:20:09Z → 07:23:30Z, exit 0 |
| Location | `~/Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial/sources/`, the consented folder |
| Data | 50 generated random-byte files (34,493 to 1,017,043 bytes, seeded per registry index), never audio |
| Every cycle | [`sources-holdout/src-on-prov-001-cycles.jsonl`](sources-holdout/src-on-prov-001-cycles.jsonl): 100 records |

Each file was uploaded, then evicted with `brctl evict`. It then ran one **OFF** cycle followed by one **ON** cycle.

| Set | Frozen | Executed | Passed | Key observations |
| --- | ---: | ---: | ---: | --- |
| **OFF** (default-OFF, metadata only) | 50 | 50 | **50** | **0** download requests and **0** progress queries. 50/50 were still placeholders after a 15 s hold (`downloadingStatus=notDownloaded`, `SF_DATALESS`). lstat changed only `dataless` relative to before eviction. Residency reported `cloudPlaceholder`, transfer `notRequested(availabilityOff)`. Scopes 200 started / 200 stopped. |
| **ON** (default-ON source availability) | 50 | 50 | **50** | See the breakdown below. |

ON cycles: **50/50 reached `idle`, with bytes identical** to the generated data (harness digest). Scopes were 437 started / 437 stopped. There were 67 download requests: 1 per cycle, plus 1 retry per cancel cycle.

| Variant (by `index % 3`) | Cycles | Median time to local | Max time to local |
| --- | ---: | ---: | ---: |
| automatic | 17 | 0.32 s | 0.85 s |
| cancel-then-retry | 17 | 4.07 s | 4.24 s |
| explicit Make Available with the setting OFF | 16 | 0.32 s | 0.42 s |

- **Progress:** 160 percent queries, **0 known fractions**. Every ON cycle showed "progress unknown".
- **After cancel:** in **17/17** cancel cycles, the item was `current` (downloaded) at +1 s and +3 s. The app's cancel does not stop iCloud. The harness then re-evicted the item and an explicit Retry ran.
- **Not observed:** offline. No network toggling is permitted.

**Folder lifecycle, recorded:** the trial root existed and was empty before the run. The harness created `sources/`, and at the end `sources/` was **deleted** (`deleted=true`; root entries after: `[]`). The empty trial root was left in place, as found.

**Provider finding (filed as #78, not a holdout failure):** after rematerialization, lstat `mtime` differed for 50/50 files, while inode and size were unchanged and the bytes were identical. The creation and modification dates moved by **±1.19×10⁻⁷ s**. The metadata-only identity check compares dates exactly, so it reported `changed(…)` for **41/50** sources: 14 creation only, 14 modification only, 13 both. The other 9 were unchanged. Identity is not part of this entry's frozen truth, and zero source writes still holds: no app write API exists, and the bytes are unchanged. The fix belongs in a separate PR.

### Run C: M1-REF-019 generator and WWCore model operations (**not holdout**)

Run C is **harness and model-operation evidence only. It does not count as M1-REF-019 holdout.**
- **Undo is not product undo:** its undo/redo check runs against the harness's own snapshot editor, so the exact-state result is trivially true and is not reported.
- **One holdout per revision:** protocol §4 allows one holdout run per frozen revision. The single M1-REF-019 holdout will be **Run D**, run through `SetupEditCommands` with a real `UndoManager` once `WWEpisodeSetup` (#55) is on main.
- **Same seeds:** Run C used the holdout seed derivation. Run D uses the same deterministic episodes.

| Field | Value |
| --- | --- |
| Commit | `2f7594dbb9b212c4140b2df90146470b8e89b5f2` (clean tree) |
| Test tree `Packages/WaveWranglerKit/Tests/WWCoreTests` | `5a06545891325c47d06019de2fbce1fa2e2bb992` |
| Code under test `WWCore` | `b36189e5c3c6343d9e52937dd83884c6a8950b0b` |
| Command | `swift test … --filter OrganizationFixtureTests` |
| Time | 2026-10-05T07:24:23Z, exit 0 |
| Records | [`sources-holdout/ref-019-wwcore-cases.jsonl`](sources-holdout/ref-019-wwcore-cases.jsonl): 110 generated episodes. The `split` field names the seed split; these are **not** holdout results. |

**What Run C shows (WWCore pure operations, generator sanity):**
- 110 generated episodes: 348 groups, 1,559 clips and 346 speakers across the 100 holdout-seeded episodes. 774 clips had a known channel count and 785 unknown.
- 2,092 applied corrections. All 337 refusals predicted by the independent oracle were refused, and each left the model unchanged.
- Corrections never changed recorder groups or source placement.
- Observations stayed equal to the generated metadata. Duration and sample rate stayed `unknown`.
- No label became `userConfirmed` without an explicit confirming edit to that item.
- A primary change never retargeted another speaker.

**Not evidenced by Run C:**
- **Named undo restores exact state:** needs product undo; deferred to Run D.
- **"Primary change marks dependents stale":** **not evidenced**. Schema v1 has no dependent derived work to mark stale, so this clause cannot pass as written. It needs a Lead freeze revision (N/A for schema v1, or an M2+ pointer) and is not claimed.

### Run D: M1-REF-019 holdout through `SetupEditCommands` and a real `UndoManager`

This is the single M1-REF-019 holdout run for `m1-freeze-1`.

| Field | Value |
| --- | --- |
| Commit | `e3a057030a2a30ffe3189994d259b047d0d8b5c0` (contains the freeze `2fcf4d7` and #55 `f670180`; clean tree) |
| Test tree `Packages/WaveWranglerKit/Tests/WWEpisodeSetupTests` | `02a11d4adecb5dbb9f546b7fa40a8721b1375f91` |
| Code under test `Packages/WaveWranglerKit/Sources/WWEpisodeSetup` | `10a39895a9baa76220d8dee951694b9c49b6a299` |
| Code under test `Packages/WaveWranglerKit/Sources/WWCore` | `c310389c4b41ebde80c5dabaea12fd5376f5d9ba` |
| Command | `WW_REF019_HOLDOUT=1 swift test … --filter OrganizationHoldoutTests` |
| Time | 2026-10-05T11:00:08Z, exit 0 |
| Every episode | [`sources-holdout/ref-019-run-d-cases.jsonl`](sources-holdout/ref-019-run-d-cases.jsonl): 110 records (100 holdout, 10 calibration) |

**Method:**
- **Product path:** every edit goes through the product command layer, `WWEpisodeSetup.SetupEditCommands`: New Recorder Group, Import N Sources, Set Epoch, Start New Epoch, Set Channel, Assign Speaker, New Speaker, Change Primary and Change Backup.
- **Editor:** the editor mirrors the app's `ShowDocumentStore.apply`. A refused operation changes nothing; an operation that returns an equal model registers no undo; otherwise there is one named undo step holding the exact prior value, on a real Foundation `UndoManager` with one group per command.
  - **Limitation:** the app's `ShowDocumentStore` itself lives in the app target, which package tests cannot link. The mirror is a line-for-line copy of its `apply` / `replace` logic.
- **Refusals:** an independent oracle, written from the operations' documented rules, predicts every refusal.
- **Holdout gating:** the holdout split only runs with `WW_REF019_HOLDOUT=1`. Ordinary runs and CI execute the calibration split only, so the frozen holdout ran exactly once.

**Holdout results:**

| Measure | Value |
| --- | ---: |
| Episodes passed | **100 / 100** (0 failed) |
| Recorder groups | 346 |
| Clips | 1,569 (787 with a known channel count, 782 unknown) |
| Speakers | 348 |
| Commands issued | 2,443 |
| Applied, each one named undo step | 1,724 |
| No-op commands (no undo registered) | 388 |
| Refusals predicted by the oracle | 331 |
| Refusals by the product | 331 (each left the model unchanged and registered no undo) |
| Undo steps / redo steps | 1,724 / 1,724, each restoring the exact model with the expected action name |

**Calibration** (10 episodes, reported separately): 10/10 passed, 204 undo steps, 25/25 refusals predicted.

| Truth clause (frozen) | Run D result |
| --- | --- |
| Group clock distinct from clip start | **Passed.** Every recorder group's clock note, name and device were unchanged by all edits. Clip epochs only extend a group's epoch list; existing epochs keep identity and order. Schema v1 has no clip-start field, so this half of the check is structural. |
| UNKNOWN duration/channels stay UNKNOWN | **Passed.** Every source's observations equal the generated metadata after every edit. Duration and sample rate always stayed `unknown`. A stated channel (Set Channel) is a placement label and never changes the observed channel count. |
| Provisional vs user-confirmed labels honest | **Passed.** Nothing became `userConfirmed` except through an explicit Change Primary / Change Backup command on that speaker's own channels. Import and Assign Speaker only ever produce provisional labels. **Mutation check:** making Assign Speaker mark roles user-confirmed fails every episode. |
| Primary change marks dependents stale | **Not evidenced.** Schema v1 has no dependent derived work to mark stale. This clause **needs a Lead freeze revision** (N/A for schema v1, or a pointer to M2+) and is **not** claimed as passed. |
| Named undo restores exact state | **Passed** via product undo: `SetupEditCommands` names on a real `UndoManager`, with exact model equality after every undo and redo step. |

## Regression re-check for #78 (not holdout)

**Fix under test:** `FileSystemFingerprint.compare` now compares creation and modification dates within **1 ms** (`timestampTolerance`). Size, file identifier, volume and type are still compared exactly, and unknown values never match. This re-check runs **50 ON-only cycles** on their own seeds (`split=recheck-78`). It is not holdout.

| Field | Value |
| --- | --- |
| Commit | `359575b487efd3a0b41edaaabb77c56676b67a2f` (contains the fix; clean tree) |
| Test tree `WWSourcesTests` | `362c66c2c85bb3533bcd38a1621708ea2827f2a0` |
| Code under test `WWSources` | `ce1cd612e73387ce132cfeeedd87c7bd2abd05a0` |
| Command | `WW_ICLOUD_TRIAL=1 WW_ICLOUD_HOLDOUT=1 WW_ICLOUD_SPLIT=recheck-78 swift test … --filter frozenHoldoutCycles` |
| Time | 2026-10-05T07:49:13Z → 07:51:22Z, exit 0 |
| Every cycle | [`sources-holdout/recheck-78-on-cycles.jsonl`](sources-holdout/recheck-78-on-cycles.jsonl) |

**Results:**
- **50/50 passed.** All reached `idle` with identical bytes.
- Variants: 17 automatic, 17 cancel-then-retry, 16 explicit with the setting OFF.
- **Identity after download: unchanged (`unverified(baselineNotUserConfirmed)`) in 50/50**, where it was 9/50 before the fix.
- **The provider shifts still occurred**, so the tolerance was exercised: nonzero creation-date deltas in 20 cycles and modification-date deltas in 22, with a maximum of 1.19×10⁻⁷ s. lstat `mtime` differed in 49/50.
- Cancel never stopped iCloud (17/17); 67 download requests in total.

**Folder:** at the start the trial root held `persistence/`, which belongs to another lane. This harness creates and removes only `sources/`. At cleanup, `sources/` was deleted and the root was empty: the other lane removed its own folder in the meantime. This harness never touches it.

## Post-freeze harness change: M1-REF-015 (#85, PR #99)

After Run A, a flaky case in M1-REF-015 (`holdout/3`, intermittent on main) was traced to **harness timing**.
- **The race:** in the "stall, then the provider completes" variant, the simulated provider could complete before the harness evaluated the published stall. The product then correctly reported `local` / `idle`.
- **The change:** PR #99 added a harness-controlled `.hold` step, so the stall is observed and evaluated before the provider continues.
- **Unchanged:** M1-REF-015's **recipe, truth, seeds (the RNG draw is kept) and counts (60 holdout + 10 calibration)**. This is harness code implementing the frozen definition, which the `m1-freeze-1` post-freeze rule allows.
- **Run A stands:** the Run A result reported above for M1-REF-015 (60/60 passed at `2f7594d`) is retained unchanged, and no extra holdout was counted. Later executions of the changed harness, in CI and stress runs, are re-executions, not additional holdout.

## Calibration and pre-freeze runs (not holdout)

| Run | Commit | What | Result |
| --- | --- | --- | --- |
| Pre-freeze (#54, #58) | various | lifecycle matrix, iCloud trial | Disclosed in `m1-freeze-1` `preFreezeExecutions`; unchanged |
| Branch calibration, pre-merge | `7087aa3` + uncommitted harness | lifecycle matrix dev run; REF-019 dev run | All passed; harness development only |
| Run C (post-merge, not holdout) | `2f7594d` | REF-019 generator plus WWCore operations | See Run C |
| Run D calibration split | `e3a0570` (and every ordinary test/CI run) | REF-019 calibration seeds through `SetupEditCommands` | 10/10 passed; tuned nothing |
| Local `scripts/test.sh` at the evidence commit, plus CI | `37f2962` | Re-execution of the same deterministic harness trees (matrix and REF-019 generator) | Identical results; not counted as additional holdout |
| Branch calibration, pre-merge | `7087aa3` + uncommitted harness | M1-SRC-ON-PROV-001 calibration split (5 OFF + 5 ON), twice | 10/10 passed each time. The first run surfaced the lstat `mtime` change, so the second added field-level and identity reporting to the harness. No gate or truth change. |

## Limits

- **Simulated vs observed:** REF-011…015 and SRC-* use simulated provider doubles. The real-provider observations are M1-SRC-ON-PROV-001 alone: iCloud Drive on this Mac, in one trial folder, synthetic files only. There are no OneDrive, Dropbox, File Provider or second-device claims.
- **Unsandboxed:** M1-REF-020 (sandboxed panel grant) is a separate GUI entry.
- **iCloud trial gaps:** offline was not observed, and no percent progress was ever reported.

## Proposed registry/evidence updates (Lead/coordinator-owned)

- Set `evidenceStatus` for M1-REF-001…017, M1-REF-018 (invariant), M1-SRC-OFF-001, M1-SRC-ON-001/002, M1-SRC-ON-002-REVIEW and M1-SRC-ON-PROV-001 to "post-freeze holdout reported: `docs/m1/evidence/sources-holdout.md`".
- Set M1-REF-019 `evidenceStatus` to **"post-freeze holdout reported (Run D); 'primary change marks dependents stale' not evidenced in schema v1, freeze revision needed"**.
- Record the M1-REF-015 post-freeze harness change (#85 / PR #99) against the registry entry. Recipe, truth, seeds and counts are unchanged.
