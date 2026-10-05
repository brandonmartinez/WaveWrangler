# M1 sources lane: post-freeze holdout evidence (`m1-freeze-1`)

**Lane:** Mac (sources). **Date:** 2026-10-05. **Freeze:** [`m1-freeze-1`](../ww-003-fixture-protocol.md#41-freeze-record-m1-freeze-1-2026-10-05), which takes effect at the PR #62 merge `2fcf4d7`. **Registry:** [`m1-fixture-registry.json`](../fixtures/m1-fixture-registry.json).

Only the runs listed under "Post-freeze holdout runs" count as holdout. Each one ran once, on a clean checkout of a commit that contains `2fcf4d7`. Every case is reported in the per-case files in [`sources-holdout/`](sources-holdout/), including failures and exclusions (there were none). The pre-freeze runs from #54/#58 and the calibration runs on this branch before the merge are calibration only, and are listed separately below.

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

### Run C: M1-REF-019 organization, WWCore phase

| Field | Value |
| --- | --- |
| Commit | `2f7594dbb9b212c4140b2df90146470b8e89b5f2` (clean tree) |
| Test tree `Packages/WaveWranglerKit/Tests/WWCoreTests` | `5a06545891325c47d06019de2fbce1fa2e2bb992` |
| Code under test `WWCore` | `b36189e5c3c6343d9e52937dd83884c6a8950b0b` |
| Command | `swift test … --filter OrganizationFixtureTests` |
| Time | 2026-10-05T07:24:23Z, exit 0 |
| Every episode | [`sources-holdout/ref-019-wwcore-cases.jsonl`](sources-holdout/ref-019-wwcore-cases.jsonl): 110 records (100 holdout, 10 calibration) |

**Holdout:** 100 episodes, **100 passed**, 0 failed. Totals: 348 recorder groups, 1,559 clips, 774 with a known channel count and 785 unknown, and 346 speakers. There were 2,092 applied corrections and 337 refusals predicted by an independent oracle. All 337 were refused, and each left the model unchanged. Undo ran 2,092 steps and redo 2,092 steps.

| Truth clause | WWCore-phase result |
| --- | --- |
| Group clock distinct from clip start | Corrections never changed recorder groups (clock note, epochs) or source placement. Schema v1 has no clip-start field, so this check is structural. |
| UNKNOWN duration/channels stay UNKNOWN | Observations always equal the generated metadata. Duration and sample rate always stayed `unknown`. |
| Provisional vs user-confirmed labels honest | No primary or role ever became `userConfirmed` without an explicit confirming edit to that item. Untargeted sources and speakers never changed. |
| Primary change marks dependents stale | **Not applicable in schema v1:** there is no dependent derived work to mark. A primary change was verified never to retarget other speakers' assignments. |
| Named undo restores exact state | Exact model equality after every undo and redo step, with matching action names. This phase uses a **harness snapshot undo** with `EditHistory` names, not `UndoManager`. |

**Pending: REF-019 with WWEpisodeSetup.** `WWEpisodeSetup` arrives with #55, which is still open. Once #55 merges, origin/main is merged here and REF-019 runs again through `SetupEditCommands` with a real `UndoManager`, added as Run D. Run C is kept unchanged.

## Calibration and pre-freeze runs (not holdout)

| Run | Commit | What | Result |
| --- | --- | --- | --- |
| Pre-freeze (#54, #58) | various | lifecycle matrix, iCloud trial | Disclosed in `m1-freeze-1` `preFreezeExecutions`; unchanged |
| Branch calibration, pre-merge | `7087aa3` + uncommitted harness | lifecycle matrix dev run; REF-019 dev run | All passed; harness development only |
| Branch calibration, pre-merge | `7087aa3` + uncommitted harness | M1-SRC-ON-PROV-001 calibration split (5 OFF + 5 ON), twice | 10/10 passed each time. The first run surfaced the lstat `mtime` change, so the second added field-level and identity reporting to the harness. No gate or truth change. |

## Limits

- **Simulated vs observed:** REF-011…015 and SRC-* use simulated provider doubles. The real-provider observations are M1-SRC-ON-PROV-001 alone: iCloud Drive on this Mac, in one trial folder, synthetic files only. There are no OneDrive, Dropbox, File Provider or second-device claims.
- **Unsandboxed:** M1-REF-020 (sandboxed panel grant) is a separate GUI entry.
- **iCloud trial gaps:** offline was not observed, and no percent progress was ever reported.

## Proposed registry/evidence updates (Lead/coordinator-owned)

- Set `evidenceStatus` for M1-REF-001…017, M1-REF-018 (invariant), M1-SRC-OFF-001, M1-SRC-ON-001/002, M1-SRC-ON-002-REVIEW and M1-SRC-ON-PROV-001 to "post-freeze holdout reported: `docs/m1/evidence/sources-holdout.md`".
- Set M1-REF-019 to "post-freeze holdout (WWCore phase) reported; WWEpisodeSetup phase pending #55", until Run D lands.
