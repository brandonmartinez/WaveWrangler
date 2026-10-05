# WW-003 — M1 fixture permission, truth, provenance and calibration/holdout protocol

**Record date:** 2026-10-04 · **Protocol author:** Lead · **Informational issue owner:** Pipeline · **Issue:** [WW-003 (#5)](https://github.com/brandonmartinez/WaveWrangler/issues/5) · **Milestone:** [M1](https://github.com/brandonmartinez/WaveWrangler/milestone/1)
**Registry:** [`fixtures/m1-fixture-registry.json`](fixtures/m1-fixture-registry.json) (`m1-fixtures-v1-draft`) · **Contracts:** [WW-009 record](ww-009-m1-contracts.md)

**Status:** PROTOCOL-DEFINED / NOT FROZEN / NOT EXECUTED. This document defines what M1 will evidence and how. It claims **no** fixture result. WW-003's M1 staged closure ([live issue](https://github.com/brandonmartinez/WaveWrangler/issues/5)) needs three things: this complete M1-applicable registry/protocol, the per-family freeze records, and the executed evidence. Later M2–M4 qualification stays in its domain issues (§8).

## 1. Basis

- The [shared fixture and calibration protocol](../planning/research.md#shared-fixture-and-calibration-protocol) sets the rules: go when 100% of entries have permission, provenance and truth; otherwise run synthetic-only and block unrepresented claims. Calibration is controlled and happens before holdout. Weaker gates need explicit Lead/Brandon approval.
- The historical foundation protocols (seed 20261004; 5,897 primary recipes, of which 169 calibration and 5,728 primary holdout) and the project-format batch (6,410 assertions) remain **historical**. They are not reused, rerun or relabelled as M1 evidence ([foundation](../research/foundation-spikes.md#ww-003-fixture-truth-and-provisional-gate-contract), [project format](../research/project-format-recovery.md#qualification-accounting)). The M1 registry uses a new seed derivation and new IDs.

## 2. Permission classes

| Class | Meaning | Entries |
| --- | --- | ---: |
| `authorized-synthetic` | Deterministic generated data in per-run temp dirs; authorized by the pasted M1 kickoff | 47 |
| `consent-relayed-manual` | Specific consent relayed by the M1 coordinator; manual use only, within stated scope | 1 |
| `pending-user-consent` | Needs an exact user answer: GUI launch/UI tests, VoiceOver, OS accessibility/display settings | 5 |
| `not-authorized` | Real iCloud/OneDrive/Dropbox, network, second device | 5 |
| `pending-coordinator-confirmation` | Variant with local side effects beyond temp files (a disk image for real disk-full) | 1 variant inside `M1-DUR-013` |

The counts are computed by the generator and stored in `counts` in the registry: 58 entries, 47 authorized-synthetic, 10 consent-blocked, 1 consent-relayed manual. The pending-user-consent and not-authorized entries together make up the 10 consent-blocked ones.

A synthetic fixture never stands in for a consent-blocked one. Until a blocked entry executes, every dependent claim stays **unsupported** and provider behavior stays **SIMULATED**.

## 3. Generation, truth and provenance rules

1. **Determinism.** Each case seed is `sha256("ww-m1-fixture|v1|" + fixtureId + "|" + split + "|" + caseIndex)`, taking the first 8 bytes as a big-endian UInt64. Calibration and holdout seeds differ through `split`, so their IDs are disjoint by construction.
2. **Location.** Everything is generated inside a per-run temporary directory created by the test harness and deleted afterwards. Nothing is generated in the repository, the user's home folders, provider folders or the app's real container. Exception: `M1-SCALE-001` artifacts may stay under the worktree's gitignored `.build/` directory while a run is in progress.
3. **Content.** "Source" files are random bytes with audio-like extensions. Nothing decodes, header-reads or previews them. The **harness** (outside the app under test) may digest them to prove zero source writes (`M1-REF-018`). The **app** never hashes sources.
4. **Truth independence.** Expected truth is declared in the registry and built by test code from the recipe, not from the code under test's output. A callback reporting success never counts as truth. Truth is the independently read-back disk state, gateway call log, scope counter or harness digest.
5. **Provenance.** Each entry records author/date, its generator owner (the lane writing it), and once frozen, the generator source hash and freeze record path.
6. **Privacy.** No personal file names, paths or content appear in fixtures, logs committed to the repo, or PR text.

## 4. Calibration, freeze and holdout

- **Calibration** may tune only non-gate implementation parameters: retry backoff, debounce values that stay inside the ≤2 s gate, buffer sizes, and harness timeouts. It may also fix harness bugs. Gate values and truth definitions are never tuned.
- **Freeze record (per family, before first holdout case).** A dated JSON committed alongside the evidence. It records: fixture ID(s), registry version, generator source hash, recipe, truth definition, calibration results summary, holdout count, gate, host (`sw_vers`, `xcodebuild -version`, cores, memory), and the commit SHA.
- **Holdout** runs once per frozen revision. Every case is reported, including failures, exclusions and abstentions. A failure is fixed by a **new** frozen revision with fresh holdout; the failed run is retained, never overwritten.
- **Counts** may increase before freeze. They may not fall below a frozen gate minimum (≥100 per boundary, ≥1,000 WW-006 lifecycle cases, 100 projects/1,000 references) without explicit Lead/Brandon approval.
- **Timing statistics:** nearest-rank p95 = value at rank `ceil(0.95 × n)`. Report first-open and warm samples separately, and always report the maximum.

## 5. M1 strata and planned counts

Full fields are in the registry. Counts are **calibration / holdout**.

### Durability: save, autosave, conflict, recovery (WW-005/010/049)

| ID | Stratum | Cal / Holdout | Permission |
| --- | --- | ---: | --- |
| DUR-001 | Explicit Save | 10 / 100 | synthetic |
| DUR-002 | Autosave ON, edit→quiescent checkpoint (**≤2 s gate**) | 20 / 100 | synthetic |
| DUR-003 | Autosave OFF: no automatic publication, dirty preserved | 10 / 100 | synthetic |
| DUR-004 | ON↔OFF transitions with queued/pending work (AS01 object-level) | 10 / 100 | synthetic |
| DUR-005 | Explicit Save under OFF | 10 / 100 | synthetic |
| DUR-006 | Injected interruption, 7 boundaries B1–B7 (**≥100 each**) | 70 / 700 | synthetic |
| DUR-007 | Conflict: external writer | 10 / 100 | synthetic |
| DUR-008 | Concurrent windows, one document | 10 / 100 | synthetic |
| DUR-009 | Two-process competing writers | 10 / 100 | synthetic |
| DUR-010 | Offline/unavailable destination (simulated) | 10 / 100 | synthetic |
| DUR-011 | Cancel at save stages (programmatic) | 10 / 100 | synthetic |
| DUR-012 | Retry after failure | 10 / 100 | synthetic |
| DUR-013 | Disk full (ENOSPC injected) | 10 / 100 | synthetic; real-volume variant pending coordinator confirmation |
| DUR-014 | Save As success/failure/cancel | 10 / 100 | synthetic |
| DUR-015 | Acknowledgement-uncertain publication + reconcile | 10 / 100 | synthetic |
| DUR-016 | Migration (synthetic older schema) | 10 / 100 | synthetic |
| DUR-017 | Corrupt show document | 10 / 100 | synthetic |
| DUR-018 | Unknown-newer show document (**100% refusal**) | 10 / 100 | synthetic |
| DUR-019 | Library↔project reconciliation interruption | 10 / 100 | synthetic |
| DUR-020 | Index deletion/rebuild (**zero semantic loss**) | 10 / 100 | synthetic |
| DUR-021 | Owned subprocess SIGKILL, 7 boundaries (**≥100 each**) | 35 / 700 | synthetic |
| DUR-022 | Unknown-newer library | 10 / 100 | synthetic |
| DUR-023 | Corrupt library + prior recovery | 10 / 100 | synthetic |
| DUR-024 | Real provider canonical locations | at consent | **not-authorized** |
| DUR-025 | Two-device conflict/relink | at consent | **not-authorized** |
| DUR-026 | Native GUI Close/Quit, AS01/AS05 replay, panel Save As cancel, Revert | at consent | **pending-user-consent** |

The publication boundaries follow the [WW-009 C3](ww-009-m1-contracts.md#c3--save-ordering-publication-and-acknowledgement-d) save order:

- **B1** after stage write, before flush
- **B2** after flush, before prior retained
- **B3** after prior retained, before coordinated publish
- **B4** during publish/replace
- **B5** after publish, before read-back
- **B6** after read-back, before library ack
- **B7** after library ack, before index update

### References and organization (WW-006/012)

| ID | Stratum | Cal / Holdout |
| --- | --- | ---: |
| REF-001 | Add reference; read-only bookmark | 10 / 60 |
| REF-002 | Stale bookmark refresh (valid access) | 10 / 60 |
| REF-003 | Regrant required | 10 / 60 |
| REF-004 | Moved | 10 / 60 |
| REF-005 | Copied | 10 / 60 |
| REF-006 | Renamed | 10 / 60 |
| REF-007 | Same-name substitute (incl. bookmark-replacement counterexample) | 10 / 60 |
| REF-008 | Denied (≠ missing) | 10 / 60 |
| REF-009 | Missing | 10 / 60 |
| REF-010 | Changed metadata | 10 / 60 |
| REF-011 | Cloud placeholder (test double) | 10 / 60 |
| REF-012 | Download progress known/unknown (double) | 10 / 60 |
| REF-013 | Download cancel (double) | 10 / 60 |
| REF-014 | Download retry (double) | 10 / 60 |
| REF-015 | Offline (double) | 10 / 60 |
| REF-016 | Scope balance under injected error/cancel (**zero leaks**) | 10 / 150 |
| REF-017 | Cross-machine relink, simulated (no access record) | 10 / 60 |
| **REF-001–017** | **WW-006 lifecycle/error/cancel holdout total** | **170 / 1,110 (≥1,000 gate)** |
| REF-018 | Zero-source-write invariant audit over all REF/SRC cases | invariant, not extra cases |
| REF-019 | Recorder groups/epochs/channels/speakers/primary-backup | 10 / 100 |
| REF-020 | Sandboxed native panel grant/regrant/relaunch | at consent (**pending-user-consent**) |

The security-scoped assertions count only when the run happens inside a sandboxed host. Runs outside the sandbox are labelled non-sandboxed.

### Source availability: separately labelled sets (WW-006/012)

| ID | Label | Cal / Holdout | Permission |
| --- | --- | ---: | --- |
| SRC-OFF-001 | **Default-OFF metadata-only set**: zero app content/hash/header/preview/decode/download requests (recording gateway + forbidden-API check) | 10 / 200 | synthetic |
| SRC-ON-001 | **Default-ON synthetic-double set**: progress/unknown/offline/cancel/retry, OFF control | 10 / 200 | synthetic |
| SRC-ON-002 | Toggle mid-transfer (double) | 10 / 100 | synthetic |
| SRC-ON-PROV-001/002/003 | Real iCloud Drive / OneDrive / Dropbox | at consent | **not-authorized** |

These sets are never pooled. Results from SRC-OFF are never cited as default-ON behavior, and synthetic-double results never qualify a real provider.

### Scale (WW-007/011)

**SCALE-001** — 100 shows (≥2 episodes each), 1,000 distinct references, collections and at least one unavailable show.

- Calibration: 20 pilot samples.
- Holdout: 600 samples = 100 first-open + 100 warm-open + 400 interactions.
- Gates: p95 open **<1 s**, interaction **<100 ms**, zero main-thread provider I/O.
- Measurement is at model/view-model level, which is authorized. Native-window timing needs GUI-launch consent.
- These are claimed-host numbers only. The macOS 26/16 GB reference is WW-052.

### Accessibility task suite (WW-007/011/012)

| ID | Scope | Permission |
| --- | --- | --- |
| A11Y-001 | Keyboard-only: all core M1 tasks (WW-004 18 tasks + source ON/OFF/unknown/offline/cancel/retry, relink, primary/backup, save/conflict/autosave ON/OFF/explicit Save) | **pending-user-consent** (GUI/XCUITest) |
| A11Y-002 | VoiceOver: same suite | **pending-user-consent** (VoiceOver) |
| A11Y-003 | 200% text, increased contrast, reduced motion, cold/warm/recovery | **pending-user-consent** (OS settings) |
| A11Y-004 | Static audit: every core control has a name/value/action and a keyboard/menu path; status text is never colour-only | synthetic (code-level; **not** a VoiceOver result) |

### User-provided disposable episode copy (`M1-USER-001`)

- **What:** a user-provided local disposable episode copy. Its path, file names and content are withheld and never recorded here, in tests, in committed logs or in PRs.
- **Consent:** relayed by the M1 coordinator on 2026-10-04. Lead has not seen the original user message; the operator confirms the scope before use.
- **Allowed use:** manual M1 import/library, recorder grouping, primary/backup and relink validation only. Read-only. No decode, analysis, hashing, preview or transcription. Never used in automated tests or the repository.
- **Recording results:** the operator records pass/fail per checklist item only.
- **Supported claim:** "the organizer workflow was manually exercised on one real episode copy". It supports no media, format, provider, accuracy or performance claim.

## 6. Totals (computed in the registry)

| Measure | Value |
| --- | ---: |
| Registry entries | 58 |
| Authorized-synthetic entries | 47 |
| Synthetic calibration cases | 555 |
| Synthetic holdout cases | 5,811 |
| WW-006 lifecycle/error/cancel holdout | 1,110 |
| Per-boundary holdout (injected / process kill) | 100 / 100 |
| Consent-blocked entries | 10 |

Denominators overlap across claims (for example, REF-018 audits REF/SRC cases), so these totals are **not additive evidence**.

## 7. Supported-claim limits

- Synthetic evidence supports claims only about the represented local strata **on the claimed host**: macOS 27.0.1, Xcode 27, 18-core Apple silicon, 128 GiB.
- It does **not** qualify any of the following: real media/formats, provider atomicity or sync, two-device behavior, power loss, TCC/panel grants, VoiceOver/human usability, or the macOS 26/16 GB reference.
- A zero-failure finite set is not a universal guarantee.
- Provider claims stay SIMULATED until DUR-024 or SRC-ON-PROV executes under consent.
- Core-workflow accessibility cannot be accepted, or transferred to Release, on the static audit alone.

## 8. Later-milestone pointers (not M1 obligations)

| Milestone | Strata | Domain issues |
| --- | --- | --- |
| M2 | Durations/rates, shared clock, unequal starts, affine/nonlinear drift, discontinuities, acoustic-delay negatives (**2/6 false accepts retained**), noise/silence/bleed/overlap | [WW-015 (#10)](https://github.com/brandonmartinez/WaveWrangler/issues/10), [WW-016 (#15)](https://github.com/brandonmartinez/WaveWrangler/issues/15), [WW-017 (#11)](https://github.com/brandonmartinez/WaveWrangler/issues/11), [WW-018 (#13)](https://github.com/brandonmartinez/WaveWrangler/issues/13) |
| M2 | Import priming/padding/rate/channel/codec | [WW-050 (#45)](https://github.com/brandonmartinez/WaveWrangler/issues/45), [WW-020 (#19)](https://github.com/brandonmartinez/WaveWrangler/issues/19) |
| M3 | English native/Whisper timing/provisioning/offline (**tokenizer network fallback retained**) | [WW-026 (#23)](https://github.com/brandonmartinez/WaveWrangler/issues/23), [WW-027 (#21)](https://github.com/brandonmartinez/WaveWrangler/issues/21) |
| M3 | Common-map shortening, mode changes, partial inverses, occurrences, crossfades, protected speech (**merged-fade footprint risk retained**) | [WW-028 (#25)](https://github.com/brandonmartinez/WaveWrangler/issues/25), [WW-043 (#40)](https://github.com/brandonmartinez/WaveWrangler/issues/40), [WW-045 (#41)](https://github.com/brandonmartinez/WaveWrangler/issues/41) |
| M3 | Review keyboard/VoiceOver | [WW-029 (#26)](https://github.com/brandonmartinez/WaveWrangler/issues/26), [WW-044 (#48)](https://github.com/brandonmartinez/WaveWrangler/issues/48) |
| M4 | Neutral stems/record/restoration, listening | [WW-036 (#34)](https://github.com/brandonmartinez/WaveWrangler/issues/34), [WW-038 (#33)](https://github.com/brandonmartinez/WaveWrangler/issues/33), [WW-040 (#37)](https://github.com/brandonmartinez/WaveWrangler/issues/37) |

## 9. Audit checklist for WW-003 M1 closure

- [ ] Every registry entry has an ID, stratum, generator, truth, permission, provenance, split and limits. The generator asserts this; an independent reviewer re-checks it.
- [ ] A freeze record exists for every executed authorized-synthetic family before its holdout.
- [ ] Every holdout result is reported, including failures and retained reruns.
- [ ] Each consent-blocked entry is either executed under relayed consent or explicitly listed as blocking its dependent claim.
- [ ] No synthetic result is cited for an unrepresented media/provider/device claim.
