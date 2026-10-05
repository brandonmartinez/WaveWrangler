# M1-DUR-025: two-device iCloud evidence (Mac + Mac mini)

**Label: two-host evidence. Synthetic data only.**
- Host A: this Mac (MacBook, macOS 27.0.1, 18-core, 128 GiB). Host B: Mac mini (Macsimus, Apple M2 Pro, macOS 27.0.1, 12-core/32 GiB).
- Both hosts use the same Apple account and iCloud Drive (user grant E).
- Headless on both hosts: `wwpersist-probe` (the WWPersistence/WWSources code under test) driven by `scripts/dur025/run.py`. No app GUI on either Mac.
- Frozen definition: registry **m1-freeze-2** (`ad9af5a`), judged under protocol **§4.2.1** (`ce1eb23`, quoted below).

## Result: holdout, 100 cases, **95 pass / 5 fail**

| Cell (frozen holdout count) | Cases | Pass | Fail |
|---|---:|---:|---:|
| show-conflict (30) | 30 | **30** | 0 |
| library-conflict (30) | 30 | **30** | 0 |
| cross-machine-relink (20) | 20 | **15** | **5** |
| recovery (20) | 20 | **20** | 0 |

**The 5 failures are recorded as they are and were not re-run** (relink cases 61–65). Each failed in its **setup**: "setup did not sync within the bound".
- Host A generated three random-byte source files in the trial folder.
- Host B received `source-0` and `source-1` with matching digests.
- `source-2` never reached host B with the expected digest within the bounded wait (3 × 420 s; each case took ~1,000 s).
- The five cases started together, while library and recovery cases were also syncing. The 15 relink cases that started later all passed, in 40–133 s.
- The frozen recipe makes a bounded-wait timeout a case failure, so these count as failures. **No product truth was evaluated in those 5 cases.** Nothing was written to the sources; the harness only reads digests. The cause (iCloud delivery under load, or something in the observation on host B) **was not determined**: the trial folder was deleted after the run, as required.

## Run record

| Field | Value |
|---|---|
| Commit | `8456bcde770012d761ef6599c5db8355aeaeed22`: harness branch with main `d1aeb9f` merged. Contains `ad9af5a` (m1-freeze-2), `ce1eb23` (§4.2.1), `e0ac452` (#118) and `d1aeb9f` (#119); the clean tree and every ancestor were checked by the harness. |
| Tree IDs | WWPersistence `dea497dea6eb1510a706c43ba933fd4a375885bc` · WWPersistenceProbe `92dc8ab055386d81b99feda8ecc6b1f8d7622add` · scripts/dur025 `8286cc08029b4536ae824a57ae5ad977e7599e1a` |
| Probe | sha256 `4450c9fea3907b58ba86edfce778b83b093ea61d0067acbf26dcffe2720fe797`. The identical binary was copied to host B and its checksum verified before the run. |
| Hosts (observed) | A: Apple M5 Max, 18 cores, macOS 27.0.1 (26A434) · B: Macsimus, Apple M2 Pro, 12 cores, macOS 27.0.1 (26A434) |
| Window | 2026-10-05T18:51:30Z → 2026-10-05T19:53:33Z, run once |
| Clock offset (B − A) | start 24 ms (RTT 52.8 ms); end 190 ms (RTT 391.2 ms, network under load). Race triggers use the start offset. The race skew is seeded (0–250 ms), so offset error only shifts which host starts first. |
| Seeds | `sha256("ww-m1-fixture\|v1\|M1-DUR-025\|holdout\|" + caseIndex)`, first 8 bytes big-endian |
| Cleanup | `/Users/brandonmartinez/Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial/dur025/holdout` deleted at 2026-10-05T19:53:34Z (every case folder inside it). The emptied `dur025` folder was deleted at 2026-10-05T19:54:47Z; both Macs listed it empty first. Device-local state on both hosts was deleted. See `dur025-two-device/cleanup-record.txt`. |

Per-case records: [`dur025-two-device/holdout-results.jsonl`](dur025-two-device/holdout-results.jsonl). Each case has its seed, host outcomes, settle and surfacing times, version counts per host, detection path and verdict. Run record: [`holdout-run-record.json`](dur025-two-device/holdout-run-record.json).

## Frozen truths (m1-freeze-2, M1-DUR-025) and the holdout

> (1) Conflict detected, by a stated mechanism: in every race, at most one host's publication is acknowledged as the current revision for a given base, and any other host reports conflict or acknowledgement-uncertain (C3/C4). Shows: whenever the provider produces an unresolved NSFileVersion conflict version, it is surfaced as evidence (C4, no automatic merge) and never silently resolved; the count, including zero, is visible in the show's status; and any show race loses no edit, whether through the app-level base-check stop with the losing candidate preserved or through a surfaced provider version. Library: whenever an unresolved provider conflict version of the library file exists, it is detected on load, reload and before each update and drives L4 (changedElsewhere); an app-detected divergence (base-check conflict or changed-elsewhere) also drives L4. A provider conflict version that the app never surfaces is a failure; the absence of provider versions is reported, never assumed either way.
>
> (2) Both versions preserved: for shows, each host's edit is present after settle in the canonical file, the losing host's preserved candidate, or a surfaced NSFileVersion conflict version; zero silently lost edits. For the library, in every race, whether L4 came from a provider conflict version or from app-level detection, after L4 -> Combine (Keep Everything, ST-36) both Macs' changes (including each Mac's collections) are present in the current library on BOTH hosts; when provider conflict versions exist, each is copied to the device-local recovery store before it is marked resolved (nothing is discarded without a backup); concurrent Combines on the two hosts converge to a library containing both sides' changes.
>
> (3) No mixed revision: every reopen on either host yields one whole valid revision (checksum and payload valid) or an honest refusal; never a mixture.
>
> (4) NSFileVersion observed and reported: unresolved conflict versions and other versions are counted per case per host and reported, whatever the count; never assumed.
>
> (5) Relink needs an explicit regrant: host B never resolves a source by path or name alone; it shows a needs-relink/regrant state until the explicit choice; a moved or replaced file is reported as different, never silently substituted; zero source writes on both hosts (harness digests).
>
> (6) Recovery: work unpublished on a host stays recoverable on that host (device-local); no cross-device recovery is claimed; the app never reports Saved for content not read back on that host.
>
> (7) No provider-atomicity claim follows from any result.

| Truth | Holdout evidence |
|---|---|
| (1) Conflict detected, by a stated mechanism | **Show (30/30):** in every race, both hosts showed C3's local "Saved on this Mac" (allowed by §4.2.1). After settle, exactly one publication was current and byte-identical on both hosts. The other was **provider-surfaced**: an unresolved `NSFileVersion` conflict version, with the show's status count = 1 on **both** hosts, including the losing host. No silent last-writer-wins. **Library (30/30):** detected on load as **L4** (provider conflict version) on host A every time. |
| (2) Both versions preserved | **Show:** each host's edit is in the current file or in the surfaced conflict version; 0 silently lost. **Library:** after L4 → Combine, each Mac's seeded edit is present in the current library on **both** hosts in all 30 cases. Of the 120 host×edit checks, 108 are present as made and 12 as ST-36 suffixed copies (member-order edits; reported as copies, per the frozen Combine semantics). 30 conflict versions were backed up before resolution, and 0 were left unresolved. Host B never needed L4 in these runs: A's Combine and resolution reached B before B opened (checked directly; truth 4 below). |
| (3) No mixed revision | Every settle and reopen on both hosts read one whole valid revision with a byte-identical canonical file, in every case: show, library and recovery. |
| (4) NSFileVersion observed and reported | Counted per case per host (unresolved conflict, status count, other versions). Shows: 1 / 1 / 1 on each host in all 30. Library: 1 unresolved conflict version per host before resolution, 0 after. See the per-case records. |
| (5) Relink needs an explicit regrant | **15/15 evaluated cases:** host B, with no access record, reported `needsRegrant`, location unknown and identity unverified for every source; nothing was resolved by path or name. The explicit choice without confirmation gave `confirmationRequired`; with it, `applied`. Host A (which holds the evidence) reported the moved source as `moved(…)` (5/5) and the replaced same-name file as an identity mismatch (4/4); the untouched source matched exactly (6/6). Zero source writes on both hosts (sha256). **5 cases were not evaluated** (setup sync timeout, above). |
| (6) Recovery | **20/20.** B saves after A's r+1 (7): app-detected Conflict, B's candidate preserved, B's edit checkpoint kept, B's status never Saved. B quits and relaunches (6): B's edit checkpoint offered as an older revision, copy-only, on B only. A killed at P4 (3) / P5 (4): both hosts read the whole old revision (P4) or the whole new one (P5); A never acknowledged. No cross-device recovery is claimed. |
| (7) No provider-atomicity claim | None is made. All timings are observed; nothing here shows iCloud ordering or atomicity. Host A's publication won all 30 show races, including the 10 where host B's trigger came first. Observed only, not a property. |

### Per-cell detail (holdout; output of `scripts/dur025/summarize.py`)

| Cell | Cases | Pass | Fail | Harness error |
|---|---:|---:|---:|---:|
| show | 30 | 30 | 0 | 0 |
| library | 30 | 30 | 0 | 0 |
| relink | 20 | 15 | 5 | 0 |
| recovery | 20 | 20 | 0 | 0 |

### show
- detection paths: {"A": "current", "B": "providerSurfaced"} ×30
- hosts with a local acknowledgement: 2 host(s) ×30
- time to settle (from trigger): n=30 p50 86.1 s · p95 97.5 s · max 98.5 s
- time to surfacing on A (status count > 0): n=30 p50 76.5 s · p95 87.5 s · max 88.8 s
- time to surfacing on B (status count > 0): n=30 p50 56.0 s · p95 68.7 s · max 68.9 s
- version counts per host (unresolved conflict / status / other): {"A": {"other": 1, "status": 1, "unresolvedConflict": 1}, "B": {"other": 1, "status": 1, "unresolvedConflict": 1}} ×30
- A→B propagation of the setup revision: n=30 p50 57.1 s · p95 81.2 s · max 81.4 s

### library
- detection paths: "providerL4" ×30
- hosts with a local acknowledgement: 2 host(s) ×30
- time to settle (from trigger): n=30 p50 101.2 s · p95 122.5 s · max 122.8 s
- provider version observed on A: n=30 p50 91.6 s · p95 112.9 s · max 113.2 s
- L4 on open on A: n=30 p50 101.4 s · p95 122.7 s · max 123.0 s
- provider version observed on B: n=30 p50 75.1 s · p95 104.2 s · max 106.7 s
- L4 on open on B: n=0
- seeded edits: A:alias B:collection ×2; A:alias B:order ×4; A:alias B:recent ×1; A:collection B:alias ×1; A:collection B:collection ×1; A:collection B:recent ×1; A:order B:alias ×2; A:order B:collection ×6; A:order B:order ×2; A:order B:recent ×4; A:recent B:alias ×3; A:recent B:collection ×2; A:recent B:recent ×1
- presence of each Mac's change on each host after Combine: current ×108, copy ×12
- conflict versions backed up before resolve: 30 backups; unresolved left: 0
- A→B propagation of the setup revision: n=30 p50 43.6 s · p95 75.7 s · max 76.2 s

### relink: (not reached) fail ×5; moved pass ×5; replaced pass ×4; same pass ×6
### recovery: aKilledP4 pass ×3; aKilledP5 pass ×4; bRelaunches pass ×6; bSaves pass ×7

### Failures and harness errors: 5
- case 61 (relink): fail — {"caseIndex": 61, "durationMs": 1016197, "reason": "setup did not sync within the bound", "step": "awaitB <iCloud Drive>/WaveWrangler-M1-Synthetic-Trial/dur025/holdout/relink/case-61/sources/source-2.wav", "stratum": "relink", "verdict": "fail"}
- case 62 (relink): fail — {"caseIndex": 62, "durationMs": 1014814, "reason": "setup did not sync within the bound", "step": "awaitB <iCloud Drive>/WaveWrangler-M1-Synthetic-Trial/dur025/holdout/relink/case-62/sources/source-2.wav", "stratum": "relink", "verdict": "fail"}
- case 63 (relink): fail — {"caseIndex": 63, "durationMs": 1014147, "reason": "setup did not sync within the bound", "step": "awaitB <iCloud Drive>/WaveWrangler-M1-Synthetic-Trial/dur025/holdout/relink/case-63/sources/source-2.wav", "stratum": "relink", "verdict": "fail"}
- case 64 (relink): fail — {"caseIndex": 64, "durationMs": 1012579, "reason": "setup did not sync within the bound", "step": "awaitB <iCloud Drive>/WaveWrangler-M1-Synthetic-Trial/dur025/holdout/relink/case-64/sources/source-2.wav", "stratum": "relink", "verdict": "fail"}
- case 65 (relink): fail — {"caseIndex": 65, "durationMs": 938827, "reason": "setup did not sync within the bound", "step": "awaitB <iCloud Drive>/WaveWrangler-M1-Synthetic-Trial/dur025/holdout/relink/case-65/sources/source-2.wav", "stratum": "relink", "verdict": "fail"}

## Protocol §4.2.1 (quoted from `docs/m1/ww-003-fixture-protocol.md`, `ce1eb23`)

> #### 4.2.1 Interpretation note for `M1-DUR-025` truth 1 (Lead, 2026-10-05; recorded before any holdout case)
>
> **Question.** In a provider-level race, both Macs can publish, read back and show C3's local acknowledgement "Saved on this Mac — revision r+1" before iCloud picks a winner. Truth 7 says nothing is atomic at the provider. Read literally, truth 1's "at most one host's publication is acknowledged as the current revision" would fail every provider race by construction.
>
> **Ruling: an interpretation, not a truth change.**
> - C3 separates **local** acknowledgement ("Saved on this Mac", local coherent disk truth) from provider state ("Provider sync: unknown", which a local save never implies).
> - "Acknowledged as the current revision" in truth 1 therefore means a **cross-device** claim that a publication is the current revision. A local "Saved on this Mac" during the race is not one.
> - Truth 1 is judged at the **settle point** the recipe already defines ("wait until both hosts observe a stable file", bounded; timeout = case failure).
> - The registry entry, counts and gates are unchanged. No `M1-DUR-025` holdout case has run.
>
> **Per case, all of these must hold (show and library cells):**
> 1. **One current publication.** After settle, exactly one publication is current, and both hosts read the same whole valid revision (byte-identical canonical file, checksum valid).
> 2. **Every other acknowledged publication is accounted for.** After settle, each other host's locally acknowledged publication is either:
>    - **app-detected:** the base check stopped it as Conflict, with the losing candidate preserved; or
>    - **provider-surfaced:** it exists as an unresolved provider conflict version that the app surfaces. For shows, that means a nonzero conflict count in the show's status (C4). For the library, it means L4, then Combine as in truth 2.
>    - A losing publication that is neither app-detected nor provider-surfaced (silent last-writer-wins) is a **failure**. That is the #117 class.
> 3. **No false claim.**
>    - No host ever shows a cross-device, "synced" or "current everywhere" claim for a losing publication.
>    - After settle, a losing host never keeps showing an unqualified "Saved" for it without a conflict indication: Conflict, a show conflict count, or library L4.
>    - "Saved on this Mac" during the race is permitted, because it is local truth.
> 4. **Library.** After settle, the library is never in L1 ("ready") on a host that holds an unsurfaced conflict version, and truth 2 (Combine, then both Macs' changes current on both hosts, with a backup before resolve) holds.
> 5. **Reported per case**, as evidence, not as gates:
>    - the number of hosts that showed a local acknowledgement;
>    - time from the trigger to settle;
>    - time to surfacing (app-detected or provider-surfaced) on each host;
>    - provider conflict and other version counts on each host;
>    - which detection path fired.
>
> **Why this doesn't loosen truth 1.** Truth 1 still bans unsurfaced loss, cross-device false claims and mixed revisions. The note adds stricter after-settle requirements (3–4), adds no exclusions and changes no counts. Had a requirement been relaxed, it would have needed a new freeze revision (`m1-freeze-3`) before holdout.

## Before the holdout: disclosed runs and corrections

None of these runs is holdout evidence. All are kept unchanged under `dur025-two-device/pre-holdout/`.

| Run | Commit | Cases | Result | Notes |
|---|---|---:|---|---|
| Development smoke | `251d122` | 4 | 4/4 | Before m1-freeze-2. Found **#117** (library ignored iCloud conflict versions), fixed in #118. Disclosed in freeze-2. |
| Development calibration | `44078ec` | 10 | 10/10 | Pre-freeze-2 cells; host A's probe was rebuilt mid-run. Not calibration evidence. |
| Development check | `854983c` | 4 | 4/4 | One case per freeze-2 cell. |
| Calibration-1 | `787fdb7` | 10 | 9/10 | Relink "same": untouched source reported `changed(dates)`. |
| Calibration-2 | `f400c70` | 10 | 10/10 | Used a temporary allowance for date-only "changed" (later reverted). |
| Calibration-3 | `8fc1a8c` | 10 | **10/10** | Fixed probe; strict relink checks. The holdout ran the same harness, plus an evidence-only date field and host labels. |

**Probe-precision correction (found in calibration, before the holdout).**
- **Symptom:** calibration-1/-2 showed date-only "changed" on untouched sources (filed as #121).
- **Cause: the probe, not iCloud and not the product.** `src-record` stored WWSources access records with `JSONEncoder` `.iso8601`, which keeps whole seconds and so truncated the baseline.
- **How it was shown:** a two-host repro found host A's file dates unchanged to the µs, yet "changed" was reported immediately, before any sync. The app's `FileDeviceAccessStore` keeps full precision.
- **Fix:** the probe now uses `FileDeviceAccessStore` itself, and the "same" check is strict again. Raw source dates are recorded per relink case.
- **Side observation:** host B receives whole-second dates from iCloud.

**Harness corrections during calibration** (none after it):
- the library truth-4 check observes each host directly at open, with no containment mirror;
- the date-allowance added and then reverted (above).

**After the holdout (report-only):**
- `scripts/dur025/summarize.py` crashed while sorting relink variants, because the 5 failed cases never reached a variant. The fix labels them "(not reached)".
- This changes the `scripts/dur025` tree in this PR compared with the recorded run tree. `run.py` and the probe are unchanged; the holdout ran once, at `8456bcd`.
- CI's Swift toolchain (macOS 26 runner) rejected `bytes.withUnsafeMutableBytes` in the probe's `src-make` as ambiguous; this host's toolchain accepted it. The fix generates the same bytes into a `[UInt8]` array and wraps them in `Data`, a compile-only change. It changes the WWPersistenceProbe tree compared with the recorded run tree. Equivalence check: with seed 123456789, the holdout binary (sha256 `4450c9fe…`) and the rebuilt probe wrote byte-identical `source-0/1/2.wav` (`cmp`). The holdout was not re-run.
- The evidence doc, the copied records, this summarizer fix and this probe compile fix are the only changes after the run.

## Limits

- iCloud Drive with two Macs on one Apple account only. No OneDrive/Dropbox, offline, power-loss or provider-atomicity claim. Neither host is the macOS 26 / 16 GB reference.
- The harness is unsandboxed: the regrant is an explicit harness-supplied choice, not the powerbox panel (the sandboxed grant is M1-REF-020).
- Sync timing isn't controlled; all latencies are as observed, with the observer polling, so they are upper bounds.
- **Untested path:** every show race was resolved by the provider (both hosts acknowledged within the 0–250 ms skew). No show case reached the app-level base-check stop; that path is covered by DUR-007/-009, the single-host suites.
- Library: Combine always ran first on host A (the harness opens A, then B). Concurrent Combines on both hosts are covered by #118's unit tests, not by this holdout.
