# Project format and durable-work recovery

> **Publication notice:** This report describes archived historical evidence and phase permissions, not current execution authority. Public JSON companions are pointer-redacted and **NOT byte-identical archived mirrors**; [original versus published hashes](../planning/publication-provenance.json) are separate. Measurements, pins, artifact hashes, counts and failed controls remain unchanged. Local archive placeholders are not browsable repository links. [Current user-directed milestone policy](../planning/milestone-runbook.md) supersedes old no-issues/research-only phase restrictions without granting input consent.

**2026-10-04 · `project-format-recovery-v1` · finite batch closed with limits.**
Execution/author: Mac. Actual read-only product/evidence review and repository integration: Lead.
**Verdict: APPROVE WITH LIMITS for the observed synthetic model/local-I/O contracts and candidate recommendation; NOT format/framework adoption or production approval.**
[Sanitized-provenance final results companion](project-format-recovery-results.json) · [research ledger](../planning/research.md) · [historical backlog](../planning/backlog.md).

## Scope and provenance

The objective is preserving durable show/episode/library human work through format versions, cache loss and failed publication—not selecting a format from a successful roundtrip. Mac used standard-library Python and owned generated metadata/markers with actual local file/fsync/rename/SQLite I/O. **Native application tests: 0.** Lead read code, protocol, independently constructed expected values and existing raw records; Lead ran no runner, experiment, native API test or independent reproduction.

All prototypes, fixtures, expected truth and raw outputs exist **only** at `SCRATCH`:

```text
<research-artifacts>/research/project-format-recovery-v1/
```

The repository contains this documentary review and the public sanitized-provenance final summary companion, including the post-qualification reporting-only timing-scope amendment, not executable prototypes. It is **not byte-identical to the archived original after pointer redaction**; [original and published hashes](../planning/publication-provenance.json) are separate. Summary artifact paths are relative to `SCRATCH`.

- Initial pilot: **91/91**; corrected pilot: **103/103**. One **pre-freeze coverage correction** added three full canonical-library comparisons and nine library fault checks. Original pilot records remain; no qualification correction or weaker threshold.
- Freeze: **2026-10-04T20:26:00.877635+00:00**, 60 source/protocol/input/truth files. Qualification started **20:26:00.949329+00:00**, elapsed **127.192886s**, serial. This is finite conformance, not statistical/ML holdout.
- Mac's `verification-output.json` records 60 frozen files verified, 6,410 raw rows and 48 boundary groups; the results/ledger record zero unexpected failures. Lead matched selected reviewed hashes, audited the existing ledgers and boundary accounting, and did **not** independently rehash all 60 files or reproduce execution.
- `finalize.py` is **post-qualification reporting**, not frozen experiment code. It preserves `qualification/results-before-author-review.json`, disambiguates boundary counts by **family + representation + boundary** (the original display merged shared names), and adds author review/limits. Its later timing-scope amendment corrects final summary/author reporting only, not qualification or candidate behavior; neither reporting amendment is a qualification rerun.
- Actual host: **macOS 27.0.1/build 26A434, arm64, 137,438,953,472 bytes RAM (128 GiB), Python 3.14.8, SQLite 3.53.4**. No runtime macOS 26/16 GB or CPU-core claim.

## Actual canonical truth and full-product review

`fixtures.py` constructs typed inputs; `truth.py` imports only `json`, neither model nor encoder/decoder. Its separately authored dictionaries include the entire canonical value. `run.py:exact` compares `asdict(loaded_project)` with expected dictionaries, not merely encoded-to-decoded equality. Qualification regenerates inputs from **frozen fixture code** and reads frozen project truth; `fixture-inputs/` records the generated inputs but is not the runner's input reader. Library/resource expectations also use the frozen separate truth author. Shared authorship and deliberately similar formulas remain a common-error risk; these are **independent construction paths, not independent authorship or recordings**.

Lead inspected complete stored JSON values for rich/two-episode, partial/two-episode and rich/six-episode cases against their input/truth records, switched-primary truth/output, full library truth/output/index, migration truth/original/backup/output, raw fault/reconciliation/process/marker records and timing rows. The code's complete comparison covers all recorded fields, with these dispositions:

| Durable contract | Actual evidence | Limit / disposition |
| --- | --- | --- |
| One show, many episodes | Stable show/episode names, Unicode, comments, revision and version records; ten logical sources/show; two or six episodes. 24 fixtures × three representations. | Finite generated identities, not a production schema or arbitrary-history/resource validator. |
| Logical sources vs device access | Source IDs, names, relative hints and synthetic hints retained; marker case also retains an owned absolute hint. `AccessRecord` is separate; portable metadata omits local access/permission/bookmark fields. | Hints are not identity or permission. **No general automatic relative/absolute hint resolver**; logical-ID immutability across arbitrary revisions is not proved. |
| Recording structure | Provisional common-clock groups/evidence, repeated source occurrences, two capture epochs, channel/start fields; partial cases retain unknown channel/time and unresolved source IDs. | No measured clock synchronization, original-media identity, grouping/channel correctness or native import proof. |
| Speakers and human transcript work | Primary, backups, primary history, correction text/authoring primary/revision/comments survive complete roundtrips and three explicit valid primary switches; old primary becomes backup. Model/transcript output stays in external derived cache. | No complete primary-history transition/target validation, arbitrary reanalysis merge or model lifecycle guarantee. Human corrections must remain canonical even when derived output is stale. |
| Alignment/provenance | Anchors, gaps, accepted/unknown state, recorded evidence/provenance and map/recipe/version fields retained. | Recorded evidence is not measured DSP, a general inverse or speech-safety validation. |
| Edit decisions/history | Pending/rejected/accepted decisions, shorten/lift modes, boundaries, fades, comments, history and cursor retained. Ten malformed-contract checks cover selected cursor bounds, chain/revision/cut references, omitted accepted boundary, map evidence/map mismatch, type and extra field. | Does **not** establish general undo-state-at-cursor consistency, complete histories, mode transitions, protected speech, partial inverses or crossfade rendering. It does not retroactively fix older foundation validators. |
| Neutral export metadata | Zero origin, 48/44.1 kHz examples, 24-bit PCM WAV, settings, common-map reference, rounded cuts, required source IDs, snapshot and schema/asset/transcript/map/edit/renderer/adapter/recipe versions retained. | No encoded stems, actual rounding/DSP, original-asset regeneration, DAW interoperability or model/vocabulary/decoder version clearance. |
| Durable library vs index | 1,001 entries: ten aliases per each of 100 shows plus one unavailable entry; names/comments, two collections and their order, sidebar order, coherent revisions and unavailable metadata compare completely. | Structural metadata, **not library UI** or 1,000 distinct recordings. Newer-library behavior, complete library corruption/import/schema validation and duplicate-order semantics remain unestablished. |

Six dependency-contract checks comprise primary/map/transcript/edit/recipe mutations plus unchanged acceptance. They and the primary-switch stale cache are **serial model contracts**, not concurrent app jobs. This comparator's dependency tuple does **not** establish invalidation for source/format/epoch/channel/asset/schema/model/renderer/adapter changes; retaining version fields is not testing every dependency.

## Qualification accounting

Lead's read-only ledger audit found **6,410 unique family/case rows, 6,410 passed, 0 unexpected failures**, matching the final summary. Denominators are assertions, not independent recordings/projects or statistical confidence.

| Family | Assertions / interpretation |
| --- | --- |
| Complete project conformance | 72 = 24 fixtures × three formats: eight rich/two-episode, eight partial/two-episode, eight rich/six-episode |
| Primary switches / dependency checks / malformed validation | 3 / 6 / 10 |
| Project publication exceptions | 1,600 = 16 representation-specific barriers × 100 |
| Canonical-library exceptions | 900 = nine barriers × 100; smaller 11-entry library carries the same human-field contract |
| Deliberate corruption | 1,500 = four JSON + seven package + four SQLite families × 100 |
| Synthetic V0 migration exceptions / cancel then retry | 400 = four barriers × 100 / 100 |
| Project cancellation / newer-project refusal | 300 / 300, 100 per representation |
| Post-publication project/library reconciliation | 300, 100 per representation |
| Actual owned process exits | 400: JSON before publish, package after checkpoint, SQLite before commit and after commit, each 100 |
| SQLite main-only-copy observation | 100 assertions **overlap those after-commit exits**; not another 100 subprocesses |
| Generated-index deletion/replacement / library format snapshots | 100 / 3 |
| Generated marker checks / simulation negative controls | 7 / 5 |
| Resource comparisons | 300 full project truths + three representation-library truths + one standalone library truth |

The raw grouping and `qualification/boundary-denominators.json` agree: **48 separately named groups, each 100 cases** = 16 publication + nine library + 15 corruption + four migration + four process groups. Cancellation/refusal/reconciliation have their own denominators; do not add overlapping evidence-kind totals to family totals. The **500 actual-subprocess-evidence rows** include the 100 WAL observations within **400 owned `os._exit(73)` executions**.

Repeated injections vary owned paths but repeat substantive payloads. Mac's source waits using `subprocess.run`; selected first/last process records for all four barriers have return code 73 and matching exit-barrier records. Mac reports **zero children at finish**; Lead launched no testworker/service/helper. Neither exceptions nor owned exits prove disk-full, power loss, hardware write ordering or privileged termination.

## Representation, migration and recovery findings

| Representation | Observed local contract | Tradeoff / counterexample |
| --- | --- | --- |
| Versioned JSON + prior checkpoint | Envelope checksum over canonical payload; typed/schema/semantic validation; fsync stage; checkpoint prior whole project; local rename/current publication and directory sync. Selected damaged/missing current cases recover validated prior. | Simpler portable-project hypothesis, **not** provider atomicity. Whole-document growth, checkpoint movement/retention and real publication coordination remain gates. Checksum is integrity bookkeeping, not security/authenticity. |
| Referenced package | Immutable source/episode/manifest members; coherent current/prior pointer; checksum **and project-ID/revision context** verified before full hydration. | Lead inspected a mixed-revision sample whose manifest/member checksums were valid but header8/member7: `MEMBER_REVISION` refused it, prior recovered. Hashes alone are insufficient. Revision context reduces deduplication; failed revisions leave orphans. Cleanup/retention/provider coherence untested. |
| SQLite metadata | FULL-synchronous WAL transaction, revision head, checksummed complete payload and matching episode rows; prior rows or external JSON checkpoint on selected damage. | Comparator duplicates the complete payload, not an optimized normalized schema. In 100 actual after-commit cases, main-only copy read7 while coherent original reopen read8 with committed WAL. Arbitrary all-sidecar copying is **also unproved**; native backup/transport needs separate design. |

**SQLite constructor deficit:** truncated-header fallback is exercised through an **existing adapter opening a fresh connection**. Constructing a **new** `SQLiteStore` can fail in constructor-time connection/schema setup before `load()` fallback. Do not describe this as universal corrupt-database reopen/recovery or silently recreate the damaged database. Canonical library SQLite/schema recovery has not established a general equivalent safety envelope either.

Migration is from a **synthetic V0, not an existing WaveWrangler format**. A separately authored literal expected dictionary in `run.py:historical_expected` is frozen as `truth/v0-migrated.json`, not taken from the migration return. The two-episode old names/hints/speakers/corrections/notes survive; clock/start/channel become explicitly unknown/provisional rather than invented measurements. Original and preserved backup bytes match. Four exception barriers and explicit cancel/retry preserve V0 or coherent V1; the migration output is JSON, **not package/SQLite migration coverage**.

Unknown-newer **project** schemas refuse model load/edit, save and downsave before prior fallback can bypass refusal: 100 cases per representation; current publication bytes are compared unchanged. This is not native menu/edit enforcement, comprehensive hostile-input/JSON-duplicate validation or tested newer-library behavior.

Recovery in the tested cases selects a **whole validated current, prior or external checkpoint**, not a synthesized mixture; deliberate damage remains in owned artifacts. Checkpoint/history depth is limited. A post-publication exception is **acknowledgement-uncertain**, not successful Save: coherent project8 can coexist with library/index7. In the 300 serial cases, the harness does not advance library/index on the failed save; **explicit reopen/reconcile** then preserves aliases, comments, collections, order and unavailable entry while updating coherent revision references. This is an exercised ordering model, not an integrated native event dispatcher, cross-document transaction or multi-writer/cloud reconciliation guarantee.

## References and failed controls

Marker relink requires an explicit logical-ID choice within the owned root and exact generated-byte digest. Same filename/different bytes, wrong ID, missing marker, no explicit choice and out-of-scope choice are refused; moving the generated marker between two owned roots requires a new explicit choice. Hints remain hints. **No real-media identity, bookmark/security scope, TCC, stale grant/regrant, provider hydration or cross-machine permission proof.**

Five retained failed candidates are **simulation negative controls/simple inequalities**: lossy correction projection, naïve mixed revision, filename-only relink, missing stale guard and index-first failed save. No unsafe storage implementation was operationally exercised by these five. They pass the assertion that the simulated candidate differs from expected truth; they are not five unexpected failures. Actual guarded byte/row-corruption recovery is the separate 1,500-case family. Older numerical failures/reports remain untouched.

## Resource observations, not performance acceptance

Each representation has **100 shows / 1,000 distinct logical sources / 332 episodes**, minimum two episodes/show, plus a 1,000-available-reference/one-unavailable canonical library. Library references are aliases, not independently measured media.

| Representation | Serialize p95 ms (n100) | Save p95 ms (n100) | First full read/validate p95 ms (n100) | Warm full read/validate p95 ms (n200) | Recorded total bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| JSON | 3.683958 | 10.276250 | 49.362333 | 55.175208 | 2,219,282 |
| Package | 3.681500 | 11.971625 | 51.874375 | 78.953625 | 2,317,252 |
| SQLite | 3.636750 | 11.278958 | 50.340125 | 51.590792 | 6,164,480 |

Lead's original review recalculated read p95 from 300 existing timing rows: nearest-rank **ceil(.95 × n)**; warm n200 is two passes × 100 shows. First-after-write reads are likely OS-cached, **not cold hardware**. Serialize includes validation; save includes encoding/local I/O/transaction/fsync; read includes disk/SQL integrity, typed hydration and semantic validation (SQLite open/PRAGMAs included), excluding subsequent expected-truth equality. Tracemalloc is active during representation/project timing, including representation-library save/load.

**Reporting-scope amendment:** Mac corrected the final summary's timing-scope metadata/limit wording and `AUTHOR-REVIEW.md` through **post-qualification reporting only**. The standalone JSON library load/validate **34.799167ms** occurs **after `tracemalloc.stop()`** in frozen `run.py` and is untraced; traced allocation peak/end exclude it. Lead's original review narrowed the old summary's “all timed samples” claim here; this narrow reporting re-read replaces the stale mirror with Mac's amended final bytes instead of retaining that overbroad summary.

Mac records five pre-amendment reporting originals preserved byte-identically in `reporting-before-timing-scope-amendment/` with a preservation manifest. Mac reports the 60 frozen experiment/protocol/input/truth files, `REPRODUCE.md`, original qualification results and assertion/timing ledgers, counters, metrics, versions and run time unchanged. Lead's final-summary comparison found only the two reporting-string changes, not numerical changes. **No experiment, reporter or qualification rerun was performed in this re-read; no candidate revision, threshold relaxation or verdict change.**

Traced peak/end **3,648,462 / 1,296,993 bytes** cover the traced representation/project resource phase, excluding the standalone library sample; process-lifetime maximum RSS **49,299,456 bytes** is not a steady-state app budget. Totals include each representation's canonical library and SQLite's duplicated payload/rows, not audio or production assets. No performance threshold, statistically superior format, native open/interaction/VoiceOver result, macOS26/16GB qualification or adoption follows.

## Concrete candidate recommendation — not adoption

**Lead recommends carrying versioned single JSON + coherent prior checkpoint + external derived cache as the simplest portable-project research candidate.** Preserve package pointers as an alternative; SQLite may suit a durable library but is **not selected**. The timing observations do not establish superiority.

The following is a **logical document layout/protocol proposal**, not a production schema, extension/UTI, app scaffold or approved backend:

| Component | Candidate contents and authority |
| --- | --- |
| Portable show document | One versioned/checksummed canonical JSON value: show, sources/logical hints, all episodes/groups/occurrences/speakers, human corrections/comments, decisions/history/cursor, map/provenance, export settings/requirements and version records. Immutable referenced media stays external; copies later. |
| Coherent recovery record | Separately identified prior whole-project checkpoint, carrying matching show/schema/revision/checksum. Stage/checkpoint/current publication have explicit boundaries; moving a document must not silently lose its recoverable history. Provider-safe placement/retention remains to be chosen. |
| Canonically durable library | Separate versioned canonical document with its own prior recovery record: user aliases/collections/order/comments, logical show references, last-known coherent revisions and unavailable records. JSON is the research baseline; backend remains open. A device-local SQLite library cannot silently replace required cloud-canonical human work. |
| Device-local access records | Logical source/project ID → machine-specific selected location/bookmark/grant/availability evidence. Never treat path/filename as identity, embed permission claims as portable authority or automatically substitute a source. Real access implementation remains gated. |
| Disposable derived state | Rebuildable library/search index, analysis/transcript/model caches, previews and render assets outside canonical human data. Cache deletion/replacement cannot remove comments, collections, corrections or decisions. Rebuild from validated canonical revisions, retaining unavailable entries. |

Proposed save ordering: validate the expected current revision and complete candidate; refuse unknown-newer edit/save/downsave; stage/checksum; retain a **validated coherent prior** without overwriting the only recoverable original; publish current revision through an evidenced native/provider protocol; acknowledge only the observed coherent outcome. A failure does not advance the index. If publication may already have happened, report acknowledgement uncertainty and offer explicit reopen/reconcile before canonical library/index acknowledgement. Never recover mixed members, silently overwrite competing work or claim serial preflight is a lock.

Proposed migration: preserve original bytes and a non-overwriting backup, explicitly decode the supported old schema into a staged new whole revision, retain unknown facts and all human work, validate against independently specified expected semantics, allow cancel/retry and publish only after checks. Recovery/refusal must work **before adapter initialization can damage/bypass originals**. Future schemas stay refusal/read-only-with-explicit-status candidates, never silently downsave.

Proposed derived dependency closure must include source/format/occurrence/epoch/channel and group/primary assignments, map, transcript/corrections, edit decisions/history, asset recipes, model/vocabulary/decoder, renderer and export/adapter/schema versions. Publish only against the still-current full dependency snapshot. The tested five-field serial guard is **partial evidence**, not this full closure or asynchronous concurrency implementation.

Accepted policy is unchanged: **OneDrive/iCloud/Dropbox user-chosen cloud canonical documents remain MVP**, with safeguards; one show/many episodes and durable library; immutable referenced originals/copies deferred; autosave **ON/configurable/OFF + explicit Save**, source download **ON/configurable/OFF/unknown**; safe common-map shortening default with editable protected-lift alternatives; DAW-neutral zero-origin stems **plus editable reconstructive cut record**, configurable 48kHz/24-bit PCM default. No local-only substitution, preference interview or Q01–Q10 reopening.

## Review disposition and owned next handoff

Mac's `AUTHOR-REVIEW.md` accepts finite contracts **in the author role**, not independent reproduction. Lead's **original actual read-only review** additionally audits source/expected-truth construction, raw denominators, full-product retention and the deficits above. It neither manufactures Design/Pipeline/Alignment approval nor verifies primary Apple APIs. **No substantive rejection, author lockout, revision request or fourth correction cycle is invoked.** Approval is for bounded reporting/candidate handoff only; unmet adoption criteria stay unmet.

The timing-scope amendment pass re-read only `results.json`, `AUTHOR-REVIEW.md`, `finalize.py`, `reporting-manifest.json` and `verification-output.json` for the correction, checked reporting hashes, compared the two changed summary strings and verified exact-byte mirroring. Mac's supplied verification still records **60 frozen files / 6,410 raw rows / 48 boundary groups** against the new final summary hash. This pass did not repeat the original domain review, recalculate metrics, re-audit preserved originals, independently rehash all frozen files or reproduce execution.

**Recommendation owner: Lead with Mac; next documentary review/handoff due 2026-10-05.** This is not a new permission or an executing trial. Bring this candidate and explicit limits to that handoff:

| Gate to resolve before stronger claims | Named owner / required disposition |
| --- | --- |
| SQLite constructor-before-recovery; complete project/history/primary transitions; unknown-newer library/refusal and canonical library corruption/migration | Lead/Mac: retain named gaps; require a separately scoped validator/recovery design and evidence before adoption. No automatic author revision in this batch. |
| Real provider/two-machine publication, checkpoint transport/retention, conflicts/offline/cancel/retry and native document status | Lead owns scope/permission; Mac owns platform evidence. OneDrive/iCloud/Dropbox operations must be evidenced individually; local fsync/rename/WAL is insufficient. |
| Multi-process writers, stale-job concurrency/full dependency closure, lost-acknowledgement reconciliation; disk-full/power loss/Save As | Lead/Mac: preserve originals and honest unresolved status; no TOCTOU/transaction/provider guarantee inferred from serial tests. |
| Native autosave OFF/Save/ON, dirty races, close/quit/recovery and ≤2s product checkpoint gate | Lead/Mac: separate from this batch. Parent-provided `partial-autosave-policy-v1` reports basic OFF/Save/ON with limited **19 asynchronous assertions**, AS01 dirty race unestablished and AS05 dirty Quit partial; **not independently reviewed here**. It neither erases historical UI failures nor completes native/autosave research. |
| Real identity/access/security scopes/regrant/immutable sources; actual audio/assets/edit restoration/speech/import/export | Lead permissions; Mac platform evidence, existing Alignment/Pipeline consultation only if separately authorized. Generated hashes/metadata are not generalized safe imports or media/security proof. |
| Native library UI, keyboard/VoiceOver, reference macOS26/16GB device; independent reproduction | Lead/Mac with existing Design consultation as separately scoped. Structural library/resource results are not UX qualification; no reproduction or further GUI launch is authorized here. |

### Local backlog integration

**Evidence only:** [WW-003](../planning/backlog.md#ww-003) gains frozen finite contract/truth coverage; [WW-005](../planning/backlog.md#ww-005) format/migration/refusal/local recovery/library comparisons; [WW-006](../planning/backlog.md#ww-006) explicit generated-marker/reference separation; [WW-049](../planning/backlog.md#ww-049) local publication/interruption/reconciliation constraints, **not provider proof**. All remain PARTIAL.

Before/after graph/status/owner/acceptance/dependency checks: **51 IDs / 196 edges / acyclic; 3 documentary-COMPLETED / 14 PARTIAL / 34 PENDING**, no changes to those item records. WW-007 remains PENDING (structural library ≠ native UI/reference-device acceptance); WW-004 remains documentary-completed only; WW-009/M1/WW-010–012 remain pending/unapproved. No new IDs, issues, Git/settings changes or app implementation. Historical numeric proofs, raw reports and product brief remain untouched; unrelated import-descriptor evidence was not rerun.

## Reviewed artifacts, hashes and reproduction recipe

SHA-256 prefixes below identify **actually reviewed artifacts**; full frozen/reporting file hashes are in their manifests. Current pins for the five reporting files replace their pre-amendment pins after the narrow re-read; frozen/raw pins retain the original review's provenance, not a new audit. The original ledger/timing/source reads are an evidence audit, not experimental reproduction.

| Artifact relative to SCRATCH | SHA-256 prefix (16 hex) |
| --- | --- |
| `results.json` | `87c4cac098d45b8f` |
| `protocol.json` | `8ceb31fa7ef74bc2` |
| `frozen-manifest.json` | `23d86ca18e902ea5` |
| `fixtures.py` | `316002534fd58ac4` |
| `truth.py` | `10b86262da65a71e` |
| `model.py` | `f5d8cd17d1c9ab39` |
| `storage.py` | `596c0469342de559` |
| `references.py` | `5835ac186eefe37f` |
| `run.py` | `38e303e82d6b6ccc` |
| `finalize.py` | `e3849fb968da0e25` |
| `AUTHOR-REVIEW.md` | `20255697daf0c9cc` |
| `REPRODUCE.md` | `c05ade2356031bfc` |
| `reporting-manifest.json` | `d99412a1ffbd146a` |
| `toolversions.json` | `68a05437332a8357` |
| `verification-output.json` | `c2c84fdc179ee964` |
| `qualification/ledger.jsonl` | `323c9c09d1f9c519` |
| `qualification/boundary-denominators.json` | `567d723b0cafac05` |
| `qualification/results-before-author-review.json` | `b194db8cf31138da` |
| `qualification/resource/timings.jsonl` | `84730ae12f025725` |
| `pilot/pilot-results.json` / `pilot-02/pilot-results.json` (also read both ledgers) | `d7c28b8d26559428` / `17683fb98793d442` |
| `truth/case-00.json` / `case-01.json` / `case-02.json` | `9ac2dd086602f6d4` / `71d86b6ec5b10e15` / `4749db12f42b9a9a` |
| `fixture-inputs/case-00.json` / `case-01.json` / `case-02.json` | `e37befba3a2dc19d` / `92451963ec8ac116` / `b037962d15875da8` |
| `truth/switched.json` / `truth/library-100.json` / `truth/v0-migrated.json` | `ce19a9e8feac7009` / `5e01e7727765b4ec` / `a10f66250707d91c` |
| `qualification/conformance/json/{00,01,02}/project.json` | `958c8820dd43085a` / `d0698460d3b524f2` / `f3bb75199a932631` |
| `qualification/switch/json/project.json` / `external-derived-cache.json` | `fde9e4755af6384f` / `5d932d863e578b96` |
| `qualification/library/canonical-library.json` / `derived-index.json` | `61832faa698b4f6e` / `41ae63c7275a48ee` |
| `qualification/markers/portable-source.json` / `local-access.json` | `977f707eb46d05c2` / `2c6b2649483d6fde` |
| `qualification/negative-controls/failed-candidates.json` | `0391251d60617275` |
| `qualification/migration-cancel/000/candidate-v1/project.json` | `5d98d38e5db574b5` |

Additional inspected records: `qualification/process/{json/before_publish,package/after_checkpoint,sqlite/before_commit,sqlite/after_commit}/{000,099}/{process-result.json,actual-exit-barrier.json}`; SQLite after-commit `main-only-copy-observation.json`; all three `qualification/reconciliation/<representation>/000/{canonical-library.json,derived-index.json}`; mixed-package `qualification/corruption/package/mixed-revision/000/revision.json` and its **explicitly referenced** members; migration-cancel `historical-v0.json` and `v0-original-preserved.json`. No parent/operator directories or historical experiment roots were scanned.

Full hash pointers:

- Archived original final scratch summary **and pre-redaction repository mirror**: `87c4cac098d45b8fbc7ab677b79da31e29e6d8d2b7d9b17750ff8fdd49615b89`. This is not the current public companion's hash.
- Frozen manifest: `23d86ca18e902ea56451966ebe3025959e1eb58e5e2518a9ef41016f94b9e41e`.
- Raw qualification ledger: `323c9c09d1f9c51912c2bcf116eb51152e40289f610b4cfbfda6abda6d470b5a`.

**Documented commands only—not executed here or authorized next work.** For a future separately authorized independent reproduction, use a newly owned copy of the nine frozen top-level source/protocol/V0/REPRODUCE files listed in `run.py:FROZEN`; do not copy generated truth/input directories, existing manifests or execution outputs into that new run. Preserve this completed SCRATCH. Replace the example path below with that new owned directory:

```sh
source "$HOME/.shell/exports-core.sh"; cd /path/to/new-owned-copy && python3 run.py pilot
source "$HOME/.shell/exports-core.sh"; cd /path/to/new-owned-copy && python3 run.py freeze
source "$HOME/.shell/exports-core.sh"; cd /path/to/new-owned-copy && python3 run.py qualify
source "$HOME/.shell/exports-core.sh"; cd /path/to/new-owned-copy && python3 run.py verify
```

The frozen corrected code includes library coverage; replaying it does **not** reconstruct the original 91-case pilot. Historical corrected pilot used `python3 run.py pilot-2` and is separately retained in `pilot-02/`. `finalize.py`/author review/reporting manifest are later documentary artifacts, not pre-qualified experiment inputs. Future output/host/timing hashes need their own provenance. **This finite batch ends with documentary integration; no further worker, reproduction, provider/audio/model/GUI trial or production launch.**
