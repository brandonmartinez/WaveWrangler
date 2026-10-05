# First foundation research batch — 2026-10-04

> **Publication notice:** This report describes archived historical evidence and phase permissions, not current execution authority. Public JSON companions are pointer-redacted and **NOT byte-identical archived mirrors**; [original versus published hashes](../planning/publication-provenance.json) are separate. Measurements, pins, artifact hashes, counts and failed controls remain unchanged. Local archive placeholders are not browsable repository links. [Current user-directed milestone policy](../planning/milestone-runbook.md) supersedes old no-issues/research-only phase restrictions without granting input consent.

**Owner / sole writer:** Lead. **Current stage:** **FINAL BATCH DONE — documentary integration complete; bounded execution stopped.** All actual reviews are received: Design and Mac approve **18/18 documentary WW-004 tasks**, Alignment approves original finite timing/mapping, Pipeline approves original finite edits and separately actual v2 with NONBLOCKING scope amendments, Mac accepts the tested LOCAL storage subset. Original 74/5,500 and supplementary 95/228 protocols retain **169 calibration / 5,728 primary heldout cases**; all frozen code, inputs, truth, manifests and raw outputs remain byte-unchanged. **3 documentary-completed / 13 partial / 35 pending**; WW-004 alone newly closes documentary acceptance. No whole research spike, native implementation/usability or production permission closes. Native/storage candidate sections remain the exact historical review extracts; final findings below narrow their interpretation without rewriting them.

Companions: [small evidence mirror](foundation-results.json), [research ledger](../planning/research.md), [backlog](../planning/backlog.md), [product direction](../planning/product-brief.md).

## Scope and reproducibility

Brandon's “start the research, I'm heading out for a bit” activates accepted Q04/Q08 bounded synthetic/disposable-prototype permission. Local authorization is recorded in `.squad/decisions/inbox/lead-foundation-execution-2026-10-04.md`. Generated fixtures only; no sample-folder metadata or recordings accessed, no dependencies/models/assets installed/downloaded, no cloud-provider writes, no speech recognition, no production code, no Git operations, no participant/listening/VoiceOver trial.

All code, manifests, fixtures, numerical results and retained generated filesystem snapshots are under:

`<research-artifacts>/research/foundation/`

This is the evidence root, abbreviated **FOUNDATION** below. Historical execution used existing `/opt/homebrew/bin/python3`, standard library only, one serial worker. No long-lived process. `protocol.py` generated independent rational clock probes and declarative per-frame edit goldens; `evaluate.py` estimated/regenerated/published separately and checked those fixtures. `freeze.py` recorded pre-holdout hashes and actual advice provenance. **Do not rerun observed splits or modify frozen algorithms/inputs/raw.** Final `FOUNDATION/final-integration-v1/` contains separately versioned documentary postprocessing/reviews/input inventory/audit, not another experiment or guard fix. The parent `verify_foundation.py` and its verification namespace remain unchanged.

Actual preparatory observation: **macOS 27.0.1, build 26A434, arm64, 137438953472 bytes (128 GiB)**; Python **3.14.8**; Apple Swift **6.4**, swiftlang-6.4.0.34.1, clang-2100.3.34.1; developer path `/Applications/Xcode.app/Contents/Developer`. This is not macOS26/16GB-reference validation or minimum-device evidence. Swift was version-observed only, no compilation/provisioning performed.

Every shell command begins `source "$HOME/.shell/exports-core.sh"`:

```sh
source "$HOME/.shell/exports-core.sh"; /opt/homebrew/bin/python3 --version && /usr/bin/swift --version && /usr/bin/sw_vers && /usr/sbin/sysctl -n hw.memsize && /usr/bin/xcode-select -p
source "$HOME/.shell/exports-core.sh"; PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/protocol.py && PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/evaluate.py --split calibration
```

Replace FOUNDATION with the evidence root. Numerical JSON writes are generated results, not shell-authored reports/source. Exact generated nonrepresentative per-case operation directories are removed by the runner, retaining case `000` per cell; roots and other session namespaces are untouched.

## WW-003 fixture, truth and provisional gate contract

Seed **20261004**. Generated manifest: `FOUNDATION/manifest.json`; separate truth: `FOUNDATION/fixtures.json`. Every entry has unique ID, seed, permission `generated-synthetic`, family/stratum and generator provenance. Calibration and holdout IDs are disjoint. Permissions do not extend to real recordings. The table originally reserved these counts in phase A; phase B executed them with amended, actually frozen recipes as recorded below.

| Family | Calibration | Reserved holdout | Truth / coverage |
| --- | ---: | ---: | --- |
| Sparse source/group/aligned maps | 8 | 160 | 20 each: unequal starts, positive/negative affine stress, segmented restart, constant/variable acoustic negatives, insufficient overlap, nonlinear rejection; 32/44.1/48/96kHz, 15s–4h durations are **sparse landmark mathematics, no long PCM** |
| Common-map edit arrays | 14 | 140 | 10 each of 14 declared safety/state strata; integer 256-frame uncut two-track arrays, independently generated retained frame indexes/output goldens |
| LOCAL publication interruptions | 36 | 3,600 | JSON/package/SQLite × baseline/safeguarded × six operation boundaries × 100 injections per holdout cell |
| Same-parent competing writers | 6 | 600 | Three formats × two candidates × 100; serialized stale-reader scenario, not parallel scheduler/provider trial |
| Errors and state contracts | 10 | 1,000 | 100 each ENOSPC/cancel/offline/unknown/newer/index/stale/Save-As/default-OFF metadata/default-ON unknown |
| **Total** | **74** | **5,500** | **5,574 entries**, no actual holdout evaluated at this stage |

**Final supplementary protocol/accounting, not a modification of the original manifest:**

| Separately frozen protocol | Calibration | Primary holdout | Manifest / truth / freeze / actual timing |
| --- | ---: | ---: | --- |
| Original `foundation-v2-prefreeze` (v1 in guard discussion) | 74 | 5,500 | `FOUNDATION/manifest.json`, `fixtures.json`, `freeze.json`; freeze **07:00:42.140275Z**, first holdout **07:00:50.961148Z–07:00:59.713093Z**, 2026-10-04 |
| Supplementary `guard-correction-v2-cycle-1` | 95 | 228 | `FOUNDATION/guard-correction-v2/manifest.json`, `fixtures.json`, independent `truth.json`, `freeze.json`; freeze **07:17:30.230995Z**, first holdout **07:17:30.471358Z–07:17:30.561887Z**, 2026-10-04 |
| **Unique primary totals** | **169** | **5,728** | **5,897 primary recipes**; IDs disjoint across protocols/splits, fresh v2 seeds/array realizations; no exclusions |

Full IDs/truth/threshold/timing/hash provenance remain in both immutable manifests/freezes and the mirror's original `fixture_protocol`, explicit `supplementary_protocols` and full `correction_protocol`. Experiment denominators **overlap and must not be summed**. Original acoustic controls are **40 of 160 maps**. Four fresh original-guard contrast fixtures are **inside v2's 228** and produce **eight ordinary/manual false-accept attempts**, not four/eight additional cases; retained raw IDs resolve the supplied review shorthand suggesting “outside228.” **15 additional storage-reader challenges plus one live-WAL observation are outside original 5,500**, reported separately rather than mixed into primary totals. Calibration is never pooled as heldout.

Truth is constructed before estimation/publication/edit execution. Estimator observations receive seeded perturbations independently of exact rational clock truth. Safety goldens use explicit masks rather than the renderer's output. Storage validates actual decoded canonical files, member hashes/revisions and independently expected old/new payloads; it does not count the publisher's own “success” as evidence.

Provisional gates remain timing p95 **≤5ms**, maximum **≤10ms**, coordinate inverse **≤0.5 source frame**, at least five windows spanning **≥80%** overlap and **≥60%** eligible windows, zero false accepts/protected losses/mixed revisions/silent stale overwrites, common integer endpoint discrepancy **≤1 frame**, and quiescent checkpoint **≤2s**. No threshold weakened. **Edit-to-quiescent ≤2s and autosave cadence are UNTESTED**; the measured publication-operation duration is not that latency and its misleading ≤2s metric acceptance annotation is removed only in final derived results, preserving the raw value and historical mirror. Coordinate inverse arithmetic and noisy estimator inverse error are separate: satisfying a map's algebraic inverse does not show estimated source timing is sub-frame accurate.

Known missing coverage blocks support claims: real waveform/podcast/speech/noise/listening distributions; device minima/16GB/thermal/hour PCM; native lifecycle/bookmarks/VoiceOver/UI; real provider transfers/two-machine sync; true full disk or power-loss recovery; models/assets/offline recognition; encoded PCM/lossy imports/SRC/channel/spectral/DAW interoperability. WW-003 can close only the permissioned synthetic protocol subset, not all fixture readiness.

### Historical phase-A calibration — before advice/freeze

First 22-case map/edit calibration passed. Coverage accounting then explicitly added eligible-window denominators and one calibration case per storage/conflict/state cell, without changing thresholds or consulting holdout outcomes. Re-generated 74-case calibration has **0 unexpected failures**. Baseline has four incoherent publication cases and three silent stale-writer overwrites in calibration; these are negative-control failures, not safeguarded passes or provider conclusions.

Historical phase-A pre-freeze manifest SHA256: `37f50c2595c3b6654dd7b0a3820e144fd422beccfccbf3b1950d396d4759380e`.
Historical phase-A pre-freeze truth SHA256: `6c91b959814de128414d1f01ef3daf99e46aed66a2657afa270d8dfdffd7f7e3`.
These were not frozen protocol hashes. `FOUNDATION/phase-a/` preserves the original code, manifest, truth, calibration, results and operation snapshots; phase-B files at the root do not overwrite that history. Initial Pipeline contract advice was still a required external gate at this handoff, not inferred from historical documentary approvals.

Calibration's four accepted sparse-map cases have maximum truth residual **0.12895784659328058ms**; exact-coordinate inverse maximum **1.1920928955078125e−7 source frame**. The 14 edit cases request 16 cuts, activate eight and refuse eight; independent array goldens/history/required-asset checks pass. These tiny calibration results do not establish held-out or real-world performance.

Executed independent `FOUNDATION/check_graph.py`: **51 unique IDs, 196 direct edges, 51/51 topological nodes, acyclic, 23 higher-ID prerequisites**; two historical completed, 14 partial, 35 pending. Dependency fingerprint remains `c6692502c03ab1f318f412ff67b4cec1a7edbe5c96cad63460d5916d30c10c43`; no dependencies/owners/criteria modified. Result is `FOUNDATION/graph-check.json`. `FOUNDATION/summarize.py` writes authoritative `results.json` and the byte-identical repository mirror; historical phase-A calibration results SHA256 `0214e1272ad08c175bf624a2bf3a1279bf0ec95deca4a4822fc6fff43b2a0d06`. Frozen-before-evaluation was honestly **false** at that pre-holdout stage, not retroactively changed.

## WW-004 documentary native M1 specification

**Candidate specification, not adopted/implemented.** Intended one-show/many-episode documents, durable library semantics and shallow sidebar. Episode groups/channels live in content, not deeply nested navigation. Library collections, corrections and user organization are canonical; a derived lookup index is rebuildable. Setup/Alignment/Review/Export are revisitable destinations; unavailable destinations expose reason and remedy. M1 itself needs no decode.

### Core task walkthrough contract

Each row has a button/menu/list/numeric alternative, stable focus/selection and VoiceOver name/value/action. These are specified alternatives, not claims of tested assistive technology.

| Core task / command | Native organization, selection and keyboard path | Honest state / recovery and VoiceOver alternative |
| --- | --- | --- |
| New Show (`File > New`, ⌘N) | Native title/location panel, show title and episode list; initial episode selected after explicit creation | Explain cloud canonical location/default autosave; cancel changes nothing; announce created show/selected episode once |
| Open (`File > Open`, ⌘O), recent | Native panel/Open Recent; unavailable library entries remain visible; reopening selects saved episode if valid | Missing, denied, cloud availability unknown and newer schema are distinct; retry/regrant/relink/read-only choices, not silent replacement |
| Durable Library / collections | Initially visible shallow sidebar; View > Show/Hide Sidebar; New Collection/Add to Collection commands replace dragging | User collections persist independently of index; rebuilding index reports progress without erasing semantics; searchable labelled list |
| Episodes | New Episode/Rename/Duplicate commands and table navigation; episode selection and workspace selection are independent | Unsaved episode context retained; removing episode requires explicit confirmation of scope, never deletes referenced source files |
| Workspaces | Setup/Alignment/Review/Export toolbar and View menu; focus stays with invoked control | Blocked destination opens explanatory status/remedy, not an inaccessible disabled-only affordance; analysis milestones remain gated |
| Import References | File > Add References, native panel; review list then explicit Confirm; Add Folder subject to separate consent | Source-download default ON/configurable/off visible before confirmation; no sample access authorized by this specification |
| Group correction | Select clips in list; Group/Ungroup/Reassign Group commands; numeric epoch/start inspector | Clock group is distinct from clip epoch/channel/speaker; UNKNOWN is valid; timestamp is not proof; named “Reassign Recorder Group” undo |
| Channel / speaker | Labelled channel/assignment table; Assign Speaker/New Speaker commands | Duration/channels remain UNKNOWN absent authorized safe metadata; provisional assignments labelled, no inferred decoding |
| Primary / backup | Inspector radio/action “Use as Primary”; keyboard table selection plus button | Confirmed primary explicit; backups retained; changing primary marks dependent work stale rather than retargeting tokens |
| Regrant / relink | File > Resolve References; native panel and per-item Resolve button; list of observed identity/location/access | Denied ≠ missing. Same-name file is not identity. Explain revision mismatch and require confirmation; no source rename/move/write |
| Source downloads ON/off | Settings and project inspector labelled switch plus per-item Make Available/Retry/Cancel | Independent location/access/residency/transfer/identity with observation time; determinate progress only when supported, otherwise “Progress unknown”; no generic provider classifier |
| Explicit Save (`File > Save`, ⌘S) | Save always available; unnamed project prompts native location | Success names durable local revision separately from provider-confirmed synchronization; disk-full/access/cancel retain dirty state/prior valid revision |
| Autosave ON/configurable/off | Settings + visible project state; controls specify enabled/cadence and next known state, not magic “cloud safe” | OFF preserves explicit Save/close prompt. ON never labels queued/failed save durable; interrupted saves recover coherently; API opt-in alone cannot implement per-document switch |
| Save As / duplicate | Native File menu/panel, explicit new identity/location semantics | Failure preserves original canonical document and edits; no accidental source copying; library adds only a completed coherent identity |
| Recovery / revert | File > Revert/Recover Revision, list of valid revisions and descriptive changes | Never overwrite suspect original while choosing; read-only comparison, recover as new copy/retry; choose prior or verified complete revision, not mixed members |
| Conflicts / multiple windows | Window menu; same document windows share revision/undo model; per-window episode/focus context | Same-parent conflicting snapshot refuses overwrite. Compare/keep both/reconcile as new revision; no unsafe automatic merge or focus stealing |
| Offline / unknown / cancel | Status area with text/icon and accessible details; retry/cancel via command/button | Offline local checkpoint ≠ cloud confirmation. Cancel preserves prior valid work; post-publication cancellation reports revision saved, follow-up incomplete, not “nothing happened” |
| Close / quit / resume | Native close/quit edited-document behavior, saved episode/sidebar context | OFF/failed autosave requires Save/Discard/Cancel; inaccessible panel returns focus to initiating control; unknown-newer is read-only, no downgrade save |

**Menus/focus/selection:** File holds native document/recovery/import actions; Edit has descriptive Undo/Redo (⌘Z/⇧⌘Z), rename and assignments; View holds sidebar/workspaces/status; Window preserves native window cycling. Return activates selected explicit action; Escape dismisses/cancels where safe. Multi-selection and inline rename preserve standard editing shortcuts; transport keys never intercept text entry. Updating a list retains stable semantic item/occurrence IDs, caret and keyboard focus; on disappearance announce reason and move focus only after user-driven action to a predictable nearby control. No waveform-only or drag-only task. Recovery/conflict sheets have labelled summaries, default nondestructive action, native focus traversal and return-focus behavior.

**Accessibility acceptance checklist:** 200% application text must keep essential names, state, controls and numeric units visible/reflowed; expandable detail instead of essential truncation. System high-contrast/appearance plus measured contrast in later prototype; status conveys text/icon, never color only. Reduced-motion removes animated pane/transport transitions and essential meaning never depends on motion. VoiceOver orders sidebar → episode/workspace → content → inspector/status, with labelled group counts, primary/backups, unknown/provisional/stale values, disabled reasons and explicit actions. Live progress announcements are throttled; errors/completion announced once, no unsolicited focus change. Design must walk all 18 rows and Mac must review feasibility before documentary WW-004 completion; real keyboard/VoiceOver/comprehension remains WW-007/WW-029.

### Lifecycle/representation comparison and counterexamples

Current Apple primary DocC JSON observed successfully **2026-10-04** (Lead; documentary retrieval, not runtime tests):

| Source | Observed evidence / implication / limitation |
| --- | --- |
| [NSDocument](https://developer.apple.com/tutorials/data/documentation/appkit/nsdocument.json) | Documents own in-memory data, one or more windows, edited state, native save/revert/undo handling; subclasses implement formats/window controllers/undo. Saving URLs must not assume names/locations. Does not prove custom coherent revisions or provider sync. |
| [autosavesInPlace](https://developer.apple.com/tutorials/data/documentation/appkit/nsdocument/autosavesinplace.json) | Default false; opt-in indicates support, not that autosave is currently running; save-operation type distinguishes actions. Per-document ON/off/cadence/recovery still needs an actual implementation experiment. |
| [DocumentGroup](https://developer.apple.com/tutorials/data/documentation/swiftui/documentgroup.json) | SwiftUI document scenes provide create/open/save and macOS document menus/multiple documents. Not evidence of configurable scheduling/conflict recovery satisfying this contract. |
| [FileDocument](https://developer.apple.com/tutorials/data/documentation/swiftui/filedocument.json) / [ReferenceFileDocument](https://developer.apple.com/tutorials/data/documentation/swiftui/referencefiledocument.json) | Value/file versus reference/snapshot serialization; single file or package is possible. Current pages display **27.2 deprecation metadata** pointing to `Document`; the host is 27.0.1 and baseline macOS26. Future-looking annotation is not an available-baseline guarantee or reason to adopt a new API. |
| [NSFileCoordinator](https://developer.apple.com/tutorials/data/documentation/foundation/nsfilecoordinator.json) | Per-operation coordination among registered presenters/processes, no benefit retaining coordinator beyond operation. Scoped permission is distinct from coordination/lock; provider completion/atomicity not promised. |

**Candidate recommendation for the next permitted native experiment:** compare NSDocument + SwiftUI views first for explicit save/autosave/recovery control, while retaining a genuine SwiftUI DocumentGroup snapshot candidate. Not an architecture decision. Counterexample: a small value-only document with adequate lifecycle controls may favor DocumentGroup and less custom plumbing; subclass complexity and incorrectly handled save URLs can make NSDocument less safe. Future `Document` annotations require pinned SDK/floor evidence, not adoption by webpage.

Representation candidates remain single versioned JSON + prior checkpoint/external immutable assets; versioned package members + validated revision pointer; SQLite canonical transaction + explicit standalone checkpoint/external asset protocol. JSON is easier to inspect but whole-history growth/schema validation matters. Packages are useful for independent assets but member visibility can mix revisions. SQLite transactions protect their database state, not external assets/provider copy; WAL/SHM/main-file visibility needs explicit treatment. Short coordinated revision comparisons/publication, not continuous project locks. In-memory working state is not a recovery guarantee; debounce/cadence/close failure behavior remains measured-design work. No format adopted and **cloud canonical MVP remains mandatory**, not silently narrowed to local-only.

## WW-049 / WW-005 / WW-006 LOCAL publication experiment contract

Executed calibration performs real generated local writes/flush/fsync/replaces, package members and SQLite transactions/read checks. Six boundary labels are before-write, partial-payload, members-written, before-publication, after-publication, library-reconcile. Exceptions are injected between operations; they are not process-kill/power-loss/provider interruptions.

Baseline JSON overwrites in place; baseline package mutates members visible via existing head; baseline database commits parts separately. Safeguarded JSON stages/checks/preserves prior snapshot then replaces; package writes immutable revision members/manifest then replaces pointer; SQLite uses one transaction with FULL synchronous/DELETE journal. Short **local** advisory lock surrounds parent-revision compare/publication; this is not a cross-machine/provider protocol. Same-parent second writer is tested serially to expose stale overwrite, not scheduler races. Independent reader checks hashes/member revision and expected payload; 15 additional corruption/stale/member/newer challenges and one live-WAL/main-only-versus-backup observation are reserved for holdout.

ENOSPC is an **injected error**, not a filled disk. Cancellation/Save-As failure stage generated data and preserve old canonical bytes. Index deletion/rebuild is actual local I/O; collections/corrections stay canonical. Offline/transfer/stale-completion/source-ON/OFF behaviors are pure explicit-state models, not native API/provider/download evidence. Bookmarks, native autosave, scopes/source identity and actual source transfers are untested. Entire WW-049/005/006 remain partial/blocked; no cloud policy changes.

## WW-014 / WW-015 / WW-016 / WW-017 timing contract

`source_frame / F + epoch = group`; positive segmented `aligned = a × group + b`, `map_ppm = 10⁶(a−1)`. Shared clock does not imply same starts. Correlation convention with equal origins: target later by positive lag needs `b = −lag/F`. Alignment's actual pre-freeze review identified the phase-A sign assertion as hardcoded: it was removed from pass criteria **before freeze**; lag/correlation sign estimation remains untested.

Exact rational truth probes are separate from noisy regression anchors. Fit per explicitly supplied capture segment, require five windows/80% span/60% eligible windows/positive slopes and residual gate. Known restart gaps are noninvertible, no smoothing across them. **Segment metadata is supplied, not discovered.** Nonlinear and weak overlap abstain.

An event regression can falsely fit constant/variable propagation delay as clock change. The unsafeguarded baseline deliberately tests that counterexample; requiring independently certified generated clock-anchor provenance is a conservative input gate, **not an acoustic-delay detector** and not proof that podcast audio yields certified anchors. Real acoustic-only alignment remains unestablished/manual/abstain. Positive supported synthetic strata alone can earn provisional residual evidence. Separate exact-map coordinate inverse from noisy-estimator source-coordinate errors; no speech timing or real device distribution claim.

## WW-025 / WW-043 / WW-036 synthetic edit and reconstruction contract

Human acceptance/nonwaivable protection and safe-shortening default remain **accepted policy**. Original fixtures constructed shortening by default and preconfigured other-overlap/mode-change lifts; they did not demonstrate UI default selection, runtime fallback or shorten→lift→undo. Explicit unsupported/gap/stale/unaccepted/meaningful/crosstalk/fade-protected cases refused, but omitted `boundary_evidence` failed open at `evaluate.py:129`. Synthetic protections are supplied annotations, not a classifier. Separate v2 fixes and tests absent metadata without claiming retroactive original-validator approval.

Half-open integer cut intervals form one union of removed ranges; adjacent/overlapping cuts never subtract twice. Every synthetic track uses the same retained frame list, zero origin, 48kHz common rate, common integer endpoints/duration; absent ranges are padded with zero. Lifts affect only target values, not common duration. Repeated sources retain occurrence IDs; removed aligned frames have no edited inverse. Boundary blends are deterministic fixed-duration linear **array crossfade mathematics**, not quality/listening evidence or a production crossfade algorithm.

Serialized records retain cuts/modes/occurrences/uncut asset hashes, a `source_recipe` label, processing-once policy and named history. Reload/restore consumes **supplied uncut aligned generated arrays**, not cleaned stems or an exercised original-media/DSP asset-building recipe; missing/changed arrays refuse. Occurrence checks cover two supplied placements/gaps; 20 fade rows/counts/weights are not independent general seam-provenance evidence. Independent frame goldens are substantive; same-renderer null is **tautological**, not independent preview/export validation. Full WW-028/036/043 remains partial; broader reconstruction/fades/listening/import/native/encoded handoff gates remain open.

## Speech documentary register — historical phase-A observation; no recognition/provisioning

Lead successfully retrieved Apple primary JSON on **2026-10-04**:

- [SpeechTranscriber](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.json): macOS26 introduction; documented `isAvailable`/supported locales/installed locales checks, not performed here. English-only policy does not prove any exact locale/device eligibility.
- [audioTimeRange](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/resultattributeoption/audiotimerange.json) and [transcriptionConfidence](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/resultattributeoption/transcriptionconfidence.json): documented attributed-result options. Timing attributes do not establish validated word boundaries; recognition confidence does not authorize cuts or replace coverage/protection/human acceptance. Missing attributes stay absent.
- [AssetInventory](https://developer.apple.com/tutorials/data/documentation/speech/assetinventory.json): Apple-hosted system-managed assets, reservations, install requests, sharing/retention/updates and later removal. No module instantiated, reservation/install/locale query/recognition performed. Exact native sizes/hashes/pinning, entitlement/signed-app/runtime/offline/network behavior remain UNKNOWN.

At phase-A handoff, pinned reachable Whisper code/model/license/size metadata and Pipeline's specific advice were **not received**, not inferred from old moving-branch source observations. The subsequent actual Pipeline source handoff is recorded below. No engine selected; library/model licenses are not legal clearance. Exact approval gates remain: (1) native locale/device-specific asset/network provisioning with size/hash unknown acknowledged and cancellability/retention/offline audit; (2) each exact Whisper artifact only after pinned source/hash/license/size metadata, plus separate dependency/native build installation if needed; (3) representative English speech rights/content-read/retention/listening participants. No cloud speech fallback/custom training.

## Phase B — actual advice, freeze and held-out results

### Prefreeze changes and independent controls

The coordinator relayed actual **Pipeline advice (not unbuilt approval)** and **Alignment's NONBLOCKING pre-freeze review**, on 2026-10-04. Their provenance and dispositions are frozen in `FOUNDATION/advice.json`. Alignment reviewed phase-A `protocol.py`/`evaluate.py`/`freeze.py`/`summarize.py`/manifest/truth/calibration, with historical snapshot prefixes `f90986654a02` / `cc772af6d951` / `37f50c2595c3` / `6c91b959814d`. No frozen files/holdout existed then. This is not final-result approval.

**Before evaluating holdout**, Lead made p95 ≤5ms an actual failure gate, not merely a reported metric: nearest-rank p95 and maximum ≤10ms over **pooled independent-truth probes from accepted maps only**. The 500 probes share 80 accepted maps; these are not 500 statistically independent recordings. Abstentions are separate, with no invented timing score. Exact inverse ≤0.5-source-frame arithmetic uses supplied analytic coordinates, not the estimated map. Estimated inverse frame error is separately reported below.

Seeded uncut edit arrays replaced the phase-A periodic source formula. `prefreeze_checks.py` audited **154 distinct edit realizations (14 calibration + 140 holdout)**, disjoint split realization hashes/IDs, all 5,574 recipe hashes, permission/truth and no exclusions. Source/observation realizations in calibration are not transformed holdout clones; storage controls intentionally reuse paired payload seeds across format/boundary cells, not claimed independent populations. Full fixtures plus recipe/truth/realization hashes freeze rates, origins, channels, occurrences, epochs, protections and expected outcomes where represented.

Handchecked controls: rational epoch/affine mapping gives **3.253s ↔ 48,000 source frames**; half-up ties; an independent eight-frame/two-stem blend golden; positive safe edit and protected/manual/high-confidence-hallucinated refusals. A planted **6ms p95 / 6ms maximum** fails the p95 gate despite satisfying the 10ms maximum. Abstained probes are excluded only from the accepted-probe timing denominator, and reject-all fails its nonvacuity check. Controls are finite arithmetic/contract tests, not recognition or physical recording proof.

The revised **74-case calibration** passed with zero unexpected failures: 4 accepted/4 abstained maps, 25 accepted probes, p95 **0.12351476378924531ms**, maximum **0.12895784659328058ms**. Four incoherent baseline publications and three stale-overwrite conflicts remain failed controls. No holdout outcomes were consulted to make these amendments.

### Actual immutable freeze and execution

**Original frozen snapshot** (called original v1 in this correction discussion; its manifest revision is `foundation-v2-prefreeze`) froze at **2026-10-04T07:00:42.140275Z**. First holdout began **07:00:50.961148Z**, ended **07:00:59.713093Z**. Original freeze/manifest/truth/generator/evaluator/calibration/controls/raw remain byte-unmodified; `frozen_before_evaluation` stays **true** for that holdout and false for historical phase A. No original holdout tuning, exclusions, overwriting or rerun. The later correction is a separate fresh revision below, not a quiet rewrite of observed truth. Table hashes are the original reviewed snapshot.

| Artifact under FOUNDATION | SHA256 |
| --- | --- |
| `manifest.json` — 74 calibration / 5,500 holdout / 5,574 total | `ed8a7b3a66a20a6c5559e3fe8fb4ec072a2fbe1cb9dbaf789aa3e6625f89d57b` |
| `fixtures.json` — independent known truth/input recipes | `6e98b517fa04e7cb3c8bb610c26bfe652577f075cdb30e4ac67e2c2abbbe6a57` |
| `freeze.json` — timestamp, thresholds and all frozen file hashes | `f077dbec66378029ebee8de2b77f2fa4617a205337d3ac6340bfc90fc7eb667c` |
| `calibration-raw.json` — amended actual calibration | `b5982a579b4a268dc2bbe4acbddfdc73b3b5baaf79f455f1c35ba832c9d698f0` |
| `holdout-raw.json` — 5,500 actual cases, plus validator/WAL observations | `86cf6d82b7961827ac9ee033e308c2b491173bf96eed83636998300122fe96f4` |
| `guard-correction-v2/original-results.json` — archived original schema-1 results/mirror snapshot | `f726b8c1c11c3b13051705a72f8f59e8847911596545c8c8b090c591fadec8b6` |

The **original mirror snapshot** was **313,981 bytes**; original raw holdout remains **2,133,153 bytes**. Original `operations/`, `edit-records/`, `validator-challenges/`, `wal-observation/` and `phase-a/` remain untouched. Original `evidence-audit.json` and `review-ready.json` are historical snapshots, not current documentation hashes/review status. The separate correction auditor below never invokes/overwrites original runners/audits or the coordinator's verifier namespace. Current schema-1 results/mirror append the correction while preserving every original experiment's cases/status/metrics.

Executed serial commands after the amended generation/calibration:

```sh
source "$HOME/.shell/exports-core.sh"; PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/prefreeze_checks.py
source "$HOME/.shell/exports-core.sh"; PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/freeze.py --advice-received 'Actual Pipeline advice and Alignment NONBLOCKING pre-freeze amendments relayed 2026-10-04 in coordinator phase-B prompt; recorded in advice.json; not final-result approval'
source "$HOME/.shell/exports-core.sh"; PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/evaluate.py --split holdout && PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/summarize.py
source "$HOME/.shell/exports-core.sh"; PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/evidence_audit.py
```

Do not execute generator/calibration/holdout over these observed frozen outputs: the scripts refuse it. For a proposed protocol correction, preserve all failures and obtain a new frozen revision with **fresh holdout**. Auditing/summarizing unchanged retained evidence is repeatable and does not consume or tune a new evaluation.

### Actual finite outcomes and limits

| Executed subset / denominator | Outcome | Scope/status |
| --- | --- | --- |
| LOCAL publication: 3 formats × 2 candidates × 6 boundaries × 100 = **3,600** injections; serial conflicts **600** | Safeguarded **1,800 + 300**: zero incoherent/stale overwrites. Maximum measured safeguarded publication operation **0.004300040993257426s** (not native autosave cadence). Baseline **400** incoherent publications and **300** silent lost edits | Local safeguarded subexperiment **passed**; baseline controls **failed**, retained. Real file writes/flush/fsync/replace/transactions with exception injection; no kill, power loss, directory-fsync durability or provider guarantee |
| Error/state contracts **1,000** | **500** real generated staging/schema/index file cases pass; **500** explicit offline/unknown/stale/source-OFF/ON state models have zero model failures | Local file subset **passed**, simulated state coverage **partial**. ENOSPC/EACCES/cancel are injected, not real full-disk/provider faults; zero simulated request count is not an OS audit |
| Sparse maps **160**: 20 each of 8 strata; **80 accepted / 80 abstained** | **500** accepted independent-truth probes sharing 80 maps: pooled p95 **0.14012763858772814ms ≤5ms**, maximum **0.20060309441216617ms ≤10ms**, zero gated false accepts/map-contract failures | Numerical gates pass; whole sparse alignment experiment **partial**. Not 500 independent recordings. Unsupported nonlinear/weak/acoustic inputs abstain, no guessed jumps |
| Exact supplied-coordinate inverse **900** probes vs estimated inverse **500** probes | Arithmetic maximum **2.384185791015625e−7 source frames ≤0.5**; estimated inverse maximum **17.15786797180772 source frames** | Arithmetic pass is **not** subframe estimator accuracy. Calibration estimated maximum was ~12.38 frames; heldout error remains openly reported |
| Acoustic-only negative control **40** cases | Unsafeguarded event regression falsely accepts **40/40** against independent clock truth; provenance-gated runner refuses all | Baseline **failed**. No acoustic identifiability/delay discriminator demonstrated |
| Distinct original edits **140**, 10 per 14 represented strata | **160 requested cuts / 80 active / 80 refused**, 60 cases with active cuts / 80 fully refused; 60 shorten/20 lift. **425 protected annotated frame observations**, zero losses. **240/240 represented ordinary/manual unsafe attempts refused**. Golden maximum **9.094947017729282e−13 array units** | Retained finite array results **passed**, not general-validator approval; omitted boundary key fail-open remains a separately recorded defect |
| Independent storage reader **15** corruption/member/newer/stale challenges; one live-WAL observation | **15/15** detected; main-only copy misses live committed WAL state, SQLite backup preserves it | Additional controls, not added to the 5,500 case denominator or treated as crash/provider validation |
| Native M1 and speech register | **0 executed runtime cases**, 18 native task rows unchanged; documentary primary sources only | WW-004 **documentary-completed** by actual Design/Mac 18/18; speech/native implementation/usability/recognition remain partial or unapproved |

Original checks cover unioned cuts, supplied speech-protection labels, explicit absent/hallucinated/reversed boundary markers (not omitted key), absent protection/map flags, uncertainty/fade support, two padded 48kHz/256-frame stems, named history/reload and supplied occurrence/gap/frame arithmetic. Quantizer is **HALF-UP `floor(x+1/2)`**, not ties-even: original safe-001 requests 54.5→55; observed requested→actual error **≤0.5 frame** remains valid. History empty→preconfigured lift→restore is not shorten→lift→undo. Missing/changed/forged/processed/stale records refuse in represented tests; restoration regenerates from supplied uncut arrays, not an exercised source/DSP recipe. All 140 original checks pass within that finite scope.

This does **not** validate arbitrary crossfades/faded lifts/gains, mixed-rate decoding/SRC, codecs, independent preview/export, full reconstruction or general validators. Same-renderer null is tautological; supplied protection truth is not speech inference. Accepted policy forbids cuts on missing evidence, but original `cut.get("boundary_evidence", "known")` violates it for omitted keys despite high-confidence/unsupported-marker negatives passing. Original defect/first frozen raw remain historical findings; correction success cannot retrospectively validate v1.

Alignment's uncovered claims stay **blocked**, not fabricated: lag/correlation sign; physically paired unequal-start recordings and negative-frame physical interpretation; disconnected graphs; independently isolated coverage thresholds; general-map occurrence/partial inverse; discovered gaps/restarts; real waveforms/podcasts/noise/bleed/SRC/listening/performance. The supported envelope is sparse event regression plus supplied segments/analytic coordinates and explicit provenance abstention.

### Pipeline's actual primary-source handoff — documentary only

`FOUNDATION/documentary-sources.json` records **Pipeline retrieval, HTTP 200 on 2026-10-04**, not Lead re-fetches. Apple DocC endpoints cover SpeechTranscriber/result options, Foundation Speech confidence/time-range attributes, supported vs installed locales, AssetInventory and installation retries; [WWDC25/277](https://developer.apple.com/videos/play/wwdc2025/277/) discusses on-device processing after provisioning. Recognition 0–1 confidence/audio-associated ranges/sample resolution are **not boundary-accuracy benchmarks**. Locale eligibility/installed assets were not queried; Apple assets are system-shared/retained/auto-updated with exact size/version/hash UNKNOWN. System-service RSS remains separate.

Pipeline's documentary SHA256: result options `d895f639beedbd8ea486c519ffc497925d3fd8decf30cbc2b59b8a59c6a2c3af`; AssetInventory `fb941a29cbe26fe6e327f19b01b74ba3fe71e22452ffb91b25c262895d43dc27`. These are **document hashes, not asset pins**.

Official Whisper source pin **`86098128c0b4f24f0e2aa2994de830614b474227`** from [commits/main](https://api.github.com/repos/openai/whisper/commits/main); [pinned raw prefix](https://raw.githubusercontent.com/openai/whisper/86098128c0b4f24f0e2aa2994de830614b474227/) for `README.md`, `LICENSE`, `whisper/transcribe.py`, `timing.py`, `__init__.py`. MIT code/weights source claims are not legal/transitive clearance. Word timing uses cross-attention DTW; token-derived word probabilities are not boundary confidence; A100 figures are not Mac performance.

| Canonical official artifact — Pipeline **HEAD only**, no model body | Advertised bytes | Expected SHA256 (not independently download-verified) |
| --- | ---: | --- |
| [base.en.pt](https://openaipublic.azureedge.net/main/whisper/models/25a8566e1d0c1e2231d1c762132cd20e0f96a85d16145c3a00adf5d1ac670ead/base.en.pt) | 145,261,783 | `25a8566e1d0c1e2231d1c762132cd20e0f96a85d16145c3a00adf5d1ac670ead` |
| [small.en.pt](https://openaipublic.azureedge.net/main/whisper/models/f953ad0fd29cacd07d5a9eda5624af0f6bcf2258be67c92b79389873d91e0872/small.en.pt) | 483,615,683 | `f953ad0fd29cacd07d5a9eda5624af0f6bcf2258be67c92b79389873d91e0872` |

No download/provisioning/recognition or engine selection occurred. Potential **separate user-return scopes**, not approvals: exact base.en artifact download only (no runtime/install/transcription); native en-US supported/installed metadata query only (no reservation/install request/recognition/microphone); then separately permissioned provisioning with unknown size/version/hash and shared updates/retries disclosed. Media/listening/offline/resource and rights/redistribution gates remain open.

## Bounded guard/mode correction — separate frozen revision

**Cycle 1 closed after actual Pipeline review, first results retained; no further cycle, tuning or algorithm correction in this batch.** Existing synthetic authorization covered this narrowly bounded correction. All new code/raw/generated evidence is in `FOUNDATION/guard-correction-v2/`; sole writer, standard library, one serial worker, no installs/Git/app source/recordings/sample metadata/provider/network/model/TCC/signing/restoration operations. `original-inventory.json` hashes **801 original files** (everything pre-existing except the expressly updated results mirror); byte-identical `original-results.json` archives the original reviewed results. Parent verifier/verification namespace untouched.

**Historical defect preserved:** original `evaluate.py:129` uses `cut.get("boundary_evidence", "known")`; omission defaults to known and can authorize shortening **and** lift, ordinary **and** manual. V1 explicit unsupported-marker tests did not cover omission. New calibration retains **4** original-guard false accepts; fresh holdout retains **8** attempts on four omitted-key cases as a **failed negative control**. These are new fixtures, not reevaluation/tuning of original holdout or eight additional independent cases. The fix requires explicit `"known"` boundary evidence, `boundary_available=True`, human acceptance, current revisions and supported typed protection/map/regions/endpoints. Null/unknown/unsupported/missing metadata fails closed with a recorded reason; no protection weakened.

Independent new IDs/seeds/array realizations are disjoint from all originals and between calibration/holdout. `protocol.py` writes manifest/inputs and separate `truth.json`; no guard/renderer imports in truth generation. Calibration is **95 cases**; manifest/truth/prototype/runner/calibration/review provenance froze at **2026-10-04T07:17:30.230995Z** before first **228-case holdout**, **07:17:30.471358Z–07:17:30.561887Z**. Both observed splits have zero unexpected correction failures. Quantizer and finite array renderer are reused from unchanged v1 behind the strict new guard; **half-up**, not ties-even. V2 is a separate schema, not silently valid old records.

| Fresh heldout subset / denominator | Actual first frozen outcome | Limit |
| --- | --- | --- |
| **168 adversarial cases**, 42 strata × shorten/lift × 2 new seeds; **336 ordinary/manual attempts** | **336/336 refused**, zero false accepts; omitted/null/unknown/unsupported boundary, evidence availability, protection/mapping, support/gap, revisions, acceptance, endpoints/modes and protected expansion cases | Finite metadata/array safety, not a general validator or speech detector |
| **28 positive cases / 56 ordinary/manual attempts** | **56/56 accepted**; safe shorten/lift, half-up requests, adjacent protected frames and safe target lift with other-speaker overlap | Reject-all cannot pass; overlap lift is an explicit choice, not automatic fallback |
| **32 genuine sequential cases / 288 observations** | Mode, boundary, evidence-loss and overlap-choice paths: actual shorten→lift→undo/redo/reload, boundary change and evidence omission/invalidation; independent cut snapshots/frame goldens match | No native UI/default/focus/accessibility, arbitrary history or automatic fallback validation |
| **192 stale dependent plans**, **320 stale/forged-cache and asset reload challenges** | **192/192 + 320/320 refused**; mutation/undo/redo invalidates old revision plans; **valid** persisted history/cursor roundtrips retain modes/boundaries and recompute the common map | All **64** missing-boundary reload challenges also corrupt cached `state_key`; **24** already lack the field. Omission rejection on reload is **not independently isolated**; `reload_record` does **not** validate malformed histories/cursors |
| **1,421 protected annotated frame observations** across attempts/transition observations | **0 losses**, independent golden maximum **0 array units** | Repeated finite observations, not statistically independent speech recordings |
| Original guard contrast subset **4 cases / 8 ordinary-manual attempts** | **8 false accepts**, retained **FAILED** | Refutes original absent-boundary guard; new pass does not retroactively validate original v1 |

Fresh input/prototype/freeze/raw SHA256:

| Artifact under `FOUNDATION/guard-correction-v2/` | SHA256 |
| --- | --- |
| `prototype.py` | `35f1f212774aa8f10ad44958053594dc4e499ef8483a0621a60ea520b6c8b9dc` |
| `manifest.json` | `d05dd547a8080e3121bf27091b9d5b2d09e2d1efd1e96419aae540145011de65` |
| `fixtures.json` | `95466d0a695dd4f7a559fbbbe61748a6028b9b97a28e20119bb31963d4ac9dc6` |
| `truth.json` | `00d4dd22c20b42c4cef63d1f844bd66152a46a98ee55d429bd803657bd9f77b8` |
| `freeze.json` | `9ad4ef23f8aeafbf518ca9a0eb7aa938cf02a92e2a4f01ed17d2f0788385cf70` |
| `calibration-raw.json` | `81540c811be2e1b11046895d5a65c3c918a23f7ce0f71ac6b381bd715a634917` |
| `holdout-raw.json` | `0e5820eb7963272c83e0a1a998c7a81283ec1ba17fb013866a2f47ef6b195ce4` |

**Historical pre-final correction mirror reviewed by Pipeline:** schema 1, **346,139 bytes**, SHA256 **`a6464a90e02a8c1e4bbb85708b0303da0ebe23bbe1f1bb2a3f9f2f09e0516e7f`**; now archived byte-identically in `FOUNDATION/final-integration-v1/preintegration-results.json`. Its pending labels and `guard-correction-v2/audit.json`, `review-ready.json`, `reviews.json`, `correction-results.json` remain historical snapshots, not current review status. `records/` retains actual serialized calibration/holdout transitions. Original/root audits are not rerun or overwritten.

**Archived original authoritative results/pre-redaction mirror:** `FOUNDATION/results.json` and the original `docs/research/foundation-results.json` were byte-identical **schema 1**, **360,608 bytes**, SHA256 **`17aae5ef68c5fbe5151aa57fbc2fe722882428855f1653118eaa16a4293941e8`**. The current public file is a pointer-redacted sanitized-provenance companion, not that byte-identical mirror; [published hashes](../planning/publication-provenance.json) are separate. **12 experiment records**, preserving all observed non-documentary statuses/case counts/numeric metric values; WW-004 documentary status alone becomes passed with zero runtime cases. Final review metadata/gates/accounting are integrated; the raw operation-duration metric keeps its exact value but loses the misleading ≤2s acceptance proxy. Final postprocessing is versioned separately under `final-integration-v1/`; every frozen v1/v2 input/code/truth/manifest/raw and all 894 pre-existing immutable evidence files are inventory-checked. No old source, graph, chart, history or review evidence is overwritten.

Executed once, serially (commands are chronological, **not permission to rerun observed splits**):

```sh
source "$HOME/.shell/exports-core.sh"; PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/guard-correction-v2/protocol.py && PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/guard-correction-v2/evaluate.py --split calibration
source "$HOME/.shell/exports-core.sh"; PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/guard-correction-v2/freeze.py && PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/guard-correction-v2/evaluate.py --split holdout
source "$HOME/.shell/exports-core.sh"; PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/guard-correction-v2/integrate.py
source "$HOME/.shell/exports-core.sh"; PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/guard-correction-v2/audit.py
```

**Remaining gates:** independently isolated omitted-boundary reload rejection and malformed history/cursor validation; general validation/occurrences/seam provenance/fades/gains/inverses; physical/acoustic/waveform/SRC/channel evidence; original-media/DSP asset building rather than supplied-array regeneration; real speech/boundaries/listening; encoded WAV/mixed rates/DAW; native UI/accessibility/assets/offline/provider/device reference. Host remains macOS27.0.1/arm64/128GiB, not macOS26/16GB. No model download/API instantiation/engine selection or broader permission.

## Review ledger and next handoff

**All actual outcomes received and integrated on 2026-10-04 from specialist read-only reviews dispatched and relayed by the Squad coordinator; the requester was away and did not author these findings. No fabricated renewal or additional review task.** Historical planning and pre-freeze advice remain separate. `guard-correction-v2/reviews.json` and `final-integration-v1/reviews.json` preserve historical coordinator-relayed disposition/findings summaries, scopes, source observations and snapshot hashes unchanged; their legacy verbatim/requester labels do not make the compressed text raw reviewer output. Current derived review metadata uses explicit summary labels, with corrected final Mac/Pipeline v2 metadata in `final-integration-v1/provenance-erratum-v1-reviews.json`. No renewed review of the final bytes is claimed. The old review-ready/pending records are historical; **no review is pending for this batch**.

| Domain | Coordinator-relayed disposition summaries (not verbatim reviewer output) | Actual reviewed scope / disposition |
| --- | --- | --- |
| Design | `Design APPROVE documentaryWW004spec only18/18tasks0blockinggaps/noamendments.` | Documentary WW-004 original lines 59–107 only, **18/18 tasks, zero blocking gaps, no amendments**. Heading-inclusive/next-heading-exclusive SHA256 **`3d98b168fe5e7dfdd2894827a22ac9091436af1e98aeb99b77a42bde66ff7ebd`** unchanged. Generic [Apple HIG accessibility JSON](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/accessibility.json) fetched by Design 2026-10-04; no Lead re-fetch. Paired actual Mac review below closes documentary WW-004; WW-007/029 empirical gates remain open. |
| Alignment | `Alignment APPROVE actualfrozen TIMING/MAPPINGscope only NONBLOCKING disclosures no rejection.` | Original actual pooled nearest-rank p95/nonempty/max gate, 500 truth probes/80 accepted/80 abstained maps, 900 supplied-coordinate inverses and separate estimated inverse verified. Disclosures incorporated outside fixed sections; no acoustic detector/physical clips/subframe estimator/general inverse/waveform/SRC/listening approval. |
| Pipeline | `Pipeline ACTUAL APPROVE retainedfiniteeditresults NONBLOCKINGscopeamendments NOTgeneralvalidatorapprove, missingguard blocksbroaderreuse, NOTartifactrejection/Leadlockout.` | Original finite edits/source-disjoint realization hashes/freeze and documentary speech scope verified. Four amendments incorporated: explicit half-up; omitted-key counterexample/fresh correction; preconfigured modes vs genuine transitions; supplied uncut-array regeneration vs unexercised source recipe/general fades/occurrences. **Not rejection/author lockout, not general-validator or v2 approval.** |
| Mac, final actual review | `APPROVE WW004 DOCUMENTARYFEASIBILITY18/18tasks no requiredamendment/rejection` | Paired Design **18/18** completes documentary WW-004 only, zero runtime cases. **ACCEPT tested LOCAL storage subset**; whole WW-005/006/049 remain partial. Native/storage exact extracts/raw/oracles/42 exemplars reviewed; excludes v2 guard. All feasibility, fault/duration/index/read-only/activity/provider/device limitations retained below. |
| Pipeline, actual v2 | `APPROVE actualfinitev2 withNONBLOCKINGscopeamendment; noartifactrejection/Leadlockout.` | Fresh independent truth/disjoint inputs/freeze and actual **228 finite cases** approved. **336 refusals / 56 accepts / 32 sequential cases / 192 stale refusals / 320 reload refusals**, zero protected losses in **1,421 repeated observations**. Nonblocking reload/history scope amendment incorporated below; no general-validator/reload-security, speech, DAW/DSP, native/storage, full-spike or production approval. |

Original reviewed snapshot prefixes (coordinator-relayed): protocol **`f116e24b4738`**, evaluator **`c0da9f7f2120`**, manifest **`ed8a7b3a66a2`**, fixtures **`6e98b517fa04`**, freeze **`f077dbec6637`**, holdout **`86cf6d82b796`**, results/mirror **`f726b8c1c11c`**, report **`4154888a2aea`**. Original reviewed results are archived under that hash; report has since incorporated scoped amendments. These hashes are snapshots, not a claim of review of current amended files.

### Mac final review — documentary feasibility and LOCAL storage

**WW-004 actual criteria:** Design walkthrough and Mac feasibility both approve all **18** named rows: New Show, Open/recent, Library/collections, Episodes, Workspaces, Import References, Group correction, Channel/speaker, Primary/backup, Regrant/relink, Source downloads ON/off, Explicit Save, Autosave ON/configurable/off, Save As/duplicate, Recovery/revert, Conflicts/multiple windows, Offline/unknown/cancel, Close/quit/resume. Native panels/menus/standard shortcuts, descriptive undo, stable focus/selection, non-drag/numeric alternatives, VoiceOver names/values/actions and text/contrast/reduced-motion/unknown-state requirements are specified and judged feasible, **not runtime-tested**. Zero required amendments/rejections. Completion means **documentary specification**, not M1 delivery, usability, accessibility or native save correctness.

**Lifecycle findings retained:** NSDocument + SwiftUI is the **first comparison candidate**, not architecture. Subclasses still implement serialization, undo and window controllers; save URLs may be temporary or unexpected. `autosavesInPlace` defaults **false**, declaring subclass capability, not running autosave, a per-document switch or cadence. DocumentGroup remains a genuine alternative: FileDocument values get automatic undo registration; ReferenceFileDocument snapshot mutations require explicit undo registration. Current document serialization is `Sendable` outside `MainActor`; DocumentGroup warns against independently reading exposed URL contents **or metadata**. Current `Document` introduction **27.0 exceeds baseline 26**; FileDocument/ReferenceFileDocument introduction **11.0**, `deprecatedAt: 27.2`, **`deprecated: false`** in retrieved docs. Future deprecation metadata is neither a runtime floor nor an observed SDK/compile result. `NSFileCoordinator` coordinates each operation with participating presenters/processes, not a continuous lock, access permission, cloud compare-and-swap or provider completion.

**Actual LOCAL storage acceptance:** independent reader/oracle and **42 retained exemplars** match raw. **3,600 publications = 3 formats × 2 candidates × 6 boundaries × 100**. Safeguarded **1,800** recover coherent old state before publication/new state after. Baseline **400** incoherent: JSON partial **100**, package partial/members **200**, SQLite partial **100**. **600 serialized stale-writer cases**: safeguarded **300** refuse/preserve writer 1, baseline **300** overwrite; no parallel race or provider experiment. **1,000 states** split **500 actual staging/schema/index filesystem cases** from **500 explicit offline/unknown-transfer/stale-completion/default-OFF/ON models**. **15/15 planted reader challenges detected**; live WAL main-only copy misses committed state while SQLite backup retains it, both outside primary 5,500. This accepts the tested local subset only; whole WW-005/006/049 remain **PARTIAL** and cloud canonical MVP stays mandatory.

**Fault and recovery limits retained:** normal exception unwind, not kill/power failure. ENOSPC/EACCES/cancel injected **after staging**, not real device/access failure or native cancellation. SQLite close/rollback is not a crash; torn pages untested, the checksum challenge is invalid JSON inside the database. `FULL`/`DELETE` protects database-only state, not external assets/provider copy. Local `flock` is cooperative, not cross-machine; packages lack directory-fsync/power-loss evidence. Library-reconcile exception may leave a partial derived index; minimal episode-count rebuild is **not full search-index recovery**. Unknown-newer read-only decision/byte preservation is **not native app save/migration validation**. `content_requests=0` is bookkeeping, **not OS activity/scopes audit**. Runtime autosave/bookmarks/providers/macOS26/16GB/VoiceOver remain untested/gated.

**Duration amendment:** maximum safeguarded operation **0.004300040993257426s** (rounded **0.004300041s**) measures only a publication operation, **not edit-to-quiescent checkpoint latency or autosave cadence**. The provisional **≤2s quiescent checkpoint gate is UNTESTED**. Final derived results retain exact `maximum_operation_seconds` without its historical misleading ≤2s acceptance annotation; frozen raw/code/manifests and both historical mirror archives remain exact bytes.

**Mac's actual Apple primary observations:** HTTP **200**, **2026-10-04 07:13:40–07:15:21 UTC**, retrieved by Mac and relayed here; no Lead re-fetch. SHA256 hashes are **document bytes, not SDK/asset pins or runtime tests**.

| Primary DocC JSON | Documentary SHA256 |
| --- | --- |
| [NSDocument](https://developer.apple.com/tutorials/data/documentation/appkit/nsdocument.json) | `213e63a6bd2a07197497b29238a40e155d723384a3c91834f66a3082b7ee0bca` |
| [autosavesInPlace](https://developer.apple.com/tutorials/data/documentation/appkit/nsdocument/autosavesinplace.json) | `e42304f4c7fb33f27f357055af25ca7cf61363cfa5141e84fbe62b6f75a0cd9e` |
| [DocumentGroup](https://developer.apple.com/tutorials/data/documentation/swiftui/documentgroup.json) | `d5b59a91ebcb42d434d594119f4e66b6390cd22bcedf8ac0113ca79fb702d771` |
| [FileDocument](https://developer.apple.com/tutorials/data/documentation/swiftui/filedocument.json) | `659e9343931b1489c087293a409ca866999922cb8f6cd3caa33ffc8f44304655` |
| [ReferenceFileDocument](https://developer.apple.com/tutorials/data/documentation/swiftui/referencefiledocument.json) | `4a7c49eec78d8ea23bfb2db455adb63192bfd66b68af62eef8df22646a57e541` |
| [Document](https://developer.apple.com/tutorials/data/documentation/swiftui/document.json) | `d4498b77f63d85634b22283cae0c93d1a85db366a809b88bd178aed1e6464e68` |
| [NSHostingView](https://developer.apple.com/tutorials/data/documentation/swiftui/nshostingview.json) | `e9b80ab7fc230c4be9af5994d7eaf1774aa5a64274ab9e10f2d99ab84c5b3496` |
| [NSFileCoordinator](https://developer.apple.com/tutorials/data/documentation/foundation/nsfilecoordinator.json) | `4428eda23bdcc4183f7c0a45d2b83dd3c00b39eb822dbe7b543f97c944b24ecb` |

**Mac reviewed historical snapshots supplied unchanged during review:** full report **`4154888a2aeab417ae1295567da85ccd4c3b3d889db3947fe7db272969a124de`**; native heading-inclusive WW-004 → WW-049 extract **`3d98b168fe5e7dfdd2894827a22ac9091436af1e98aeb99b77a42bde66ff7ebd`**, exactly Design's extract; storage heading-inclusive WW-049 → WW-014 extract **`9b9b63a3621365f2c322db31612c7ed6381ce1f9cbfde32043b05dcbe6c0271d`**. End heading is excluded in both. Lead's **`fe2ec212dc1601f0c87d5f1713c9264217ca72b869d77a3f7fe6749abc9ce14d`** is **body-only, a different scope**, not the same extract hash. Evaluator **`c0da9f7f21209e7604aba770ccf2343a1865efbf5e0b1eabc46149cdde8ea416`**, fixtures **`6e98b517fa04e7cb3c8bb610c26bfe652577f075cdb30e4ac67e2c2abbbe6a57`**, holdout **`86cf6d82b7961827ac9ee033e308c2b491173bf96eed83636998300122fe96f4`** remain unchanged. Mac **excludes v2 guard**. The final report is not falsely assigned the old full-report hash.

### Pipeline actual v2 review — finite approval and reload limits

**APPROVE actual finite v2 with NONBLOCKING scope amendment; no artifact rejection or Lead lockout.** Independent declarative truth, fresh disjoint IDs/seeds/array realizations and freeze-before-first-holdout were verified with retained v1 hashes. Actual **228 cases** retain **336/336 ordinary/manual adversarial refusals**, **56/56 positive accepts**, **32 genuine sequential mode/boundary cases**, **192/192 stale-plan refusals**, **320/320 reload challenge refusals**, **zero protected losses in 1,421 repeated finite frame observations**—not independent samples. Original half-up quantizer unchanged. **Eight v1 false accepts on four fresh cases** remain failed controls; retained raw confirms those four IDs are inside the 228 and they add no primary cases.

**Nonblocking amendment incorporated, no algorithm changes:** reload evidence is **stale/forged cache plus asset challenges and valid history-cursor roundtrips**. **All 64 “missing-boundary” reload challenges also corrupt cached `state_key`; 24 already lack the field.** This does **not independently isolate omitted-boundary reload rejection**. `reload_record` does **not validate malformed history/cursors**. Direct omitted-boundary refusals and finite sequential transitions remain valid; general validator/reload security, arbitrary persisted-state validation, real speech/word boundaries, DAW/media-DSP asset reconstruction, native/storage/full-spike and production behavior remain **unapproved**. Isolation/history validation stays an explicit next gate; **no quiet fix or fourth cycle**.

**Pipeline v2 reviewed snapshot prefixes (historical, not final hashes):** prototype **`35f1f212774a`**, protocol **`783671ead3da`**, evaluator **`c017bd82033f`**, manifest **`d05dd547a808`**, truth **`00d4dd22c20b`**, freeze **`9ad4ef23f8ae`**, holdout **`0e5820eb7963`**, results/mirror **`a6464a90e02a`**, report **`07e1658e4745`**, review-ready **`2efcf51be49f`**. The actual full pre-final report hash is **`07e1658e4745c382a84e8974cc97392e2ed3848e553fd03975ef1c2a2e0b67f0`**. Full frozen input/raw hashes are above; final metadata updates necessarily change report/results hashes and do not claim a renewed review of those final bytes.

### Final inventory and verification contract

**Batch closed, final documentary integration complete; no review pending and no further experiment/revision cycle.** No formal artifact rejection occurred, so no reviewer lockout. `final-integration-v1/reviews.json`, `input-inventory.json`, byte-identical preintegration archive, versioned postprocessor, generated integrated results and `audit.json` preserve the final evidence chain. The postprocessor changes only derived documentary review/scope/status/accounting metadata, native documentary acceptance, and the erroneous operation-duration acceptance proxy—not frozen algorithms, observations or thresholds.

**Provenance erratum only:** historical `integrated-results.json` (SHA256 `f8d32d334e0a861304d10cb2cd9b8085666e9bcce512cbaf15bfbfd10ba7a2c3`), `reviews.json`, `integrate.py` and `audit.json` are preserved. `provenance-erratum-v1.py`, corrected summary metadata, results candidate and supplementary `provenance-erratum-v1-audit.json` retain the current provenance-only amendment separately. Experiment IDs/statuses/cases/metrics, protocols, backlog progress and production policy are unchanged.

Historically, root `results.json` and the pre-redaction repository mirror were byte-identical schema 1/date **2026-10-04**, exact host **macOS27.0.1/arm64/137438953472 bytes**. The public companion now redacts local pointers; that equality is not a current-file claim. Scope retains synthetic-only true and user-media/model/dependency/provider/production false. **12 experiment records**, nonnegative integer cases, finite metrics; zero cases only documentary/blocked, all failed controls retained. Five actual review dispositions have **no pending reviews**. Base fixture protocol remains 74/5,500; explicit supplementary protocol is 95/228. Both freezes precede first holdout, original 801-file inventory and **all 894 pre-existing immutable evidence files** remain unchanged; no app source created, no frozen runner executed. Parent-verification provenance is qualified below, not asserted as an unviolated boundary.

Current dependency graph: **51 IDs / 196 edges / acyclic**, fingerprint **`c6692502c03ab1f318f412ff67b4cec1a7edbe5c96cad63460d5916d30c10c43`**. **Completed documentary:** WW-001/002 historical scopes, WW-004 actual Design/Mac 18/18. **Partial:** WW-003/005/006/014/015/016/017/025/026/028/036/043/049. Other **35 pending**. Owners/dependencies/acceptance criteria unchanged; research progress never waives a full prerequisite or named production authorization. Native/layout/file/model choices remain candidates; cloud canonical MVP, safe-shortening default and protected-manual nonwaiver unchanged. Artifact-specific legal/redistribution/transitive/patent clearance remains **UNKNOWN**.

Historical executed Lead documentary check (not rerun for this erratum; no evaluation/import of frozen prototypes):

```sh
source "$HOME/.shell/exports-core.sh"; PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/final-integration-v1/integrate.py verify
```

Reserved parent-only command — historical reference, Lead execution unconfirmed; not counted as a verified executed Lead check:

```sh
source "$HOME/.shell/exports-core.sh"; PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 <research-artifacts>/research/verify_foundation.py FOUNDATION/results.json --repo <workspace>
```

**Parent-verification provenance erratum:** retained Lead postprocessor/inventory/audit records show Lead read the reserved parent verifier to capture/compare its SHA256 despite the separation instruction; the prior audit recorded its file hash unchanged. These own records do not establish whether Lead invoked the reserved validator or whether its output namespace changed. Invocation status and output-namespace changes are **UNKNOWN**. The earlier blanket assertion of no parent verifier/namespace change is withdrawn. No parent verifier or namespace is read, run or written for this erratum.

Executed erratum documentary commands (serial postprocessing/equality only, no renewed reviews or experiments):

```sh
source "$HOME/.shell/exports-core.sh" && PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/final-integration-v1/provenance-erratum-v1.py apply
source "$HOME/.shell/exports-core.sh" && PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 FOUNDATION/final-integration-v1/provenance-erratum-v1.py verify
```

The historical final audit records actual local-link/anchor checks, schema/mirror/frozen hashes, graph/status totals, document hashes and retained footprint. The supplementary erratum audit records current report/results hashes and provenance-only equality; historical graph/frozen/link checks are preserved, not rerun. No bounded command/service remains running after these finite commands finish. Evidence is retained reproducibly, with no broad cleanup.

### Bounded next approval requests — no execution

These are **future scoped permission requests, not ordinary preferences, approval already granted, or work to execute now**. This batch has stopped.

| Approval scope / owner | Exact boundary to approve separately |
| --- | --- |
| Identified consented recordings / Pipeline + Alignment | Select **named fixtures**, rights/participant consent, independently annotated truth and exact allowed read/decode/alignment/speech/render/export/retention operations. No sample-folder browsing, metadata enumeration, private recordings or listening participant access by inference. Real boundaries/≥100 edits/≥3 listeners require their own consent and frozen rubric. |
| Native English metadata only / Pipeline + Mac | Named device/OS and exact English locale (for example en-US), availability/**supported versus installed** metadata checks only. **No assets, module reservation/install, recognition, microphone, TCC or implicit network provisioning**. Supported does not mean installed or accurate. |
| Later native asset provisioning / Pipeline + Mac | Separate named locale/device/module/network/asset operations; disclose **unknown exact size/hash/version**, shared retention/updates, retries/cancellation and subsequent offline/system-activity audit. Metadata-query consent does not authorize provisioning. |
| Exact official Whisper artifact / Pipeline | Download only [base.en.pt](https://openaipublic.azureedge.net/main/whisper/models/25a8566e1d0c1e2231d1c762132cd20e0f96a85d16145c3a00adf5d1ac670ead/base.en.pt), advertised **145,261,783 bytes**, expected SHA256 **`25a8566e1d0c1e2231d1c762132cd20e0f96a85d16145c3a00adf5d1ac670ead`**; verify downloaded bytes only after approval. Pinned source claims MIT code/weights, **not legal/transitive clearance**. Download, dependency/runtime installation, native builds and transcription/media access are distinct approvals; none occurred. |
| Named provider disposable synthetic trial / Mac | Exact provider/version and **user-designated DISPOSABLE synthetic folder**, permitted files/save/conflict/offline/cancel/transfer operations and **allowed network/cloud writes**. Separate named second machine/account/folder permissions for two-machine tests; no user-folder selection/browsing, source writes or provider trial now. |
| Reference device and human accessibility/listening / Mac + Design + domain owners | Actual **macOS26/16GB Apple-silicon reference/device access**, named fixtures and thermal/long-workload operations; consented keyboard/VoiceOver/usability/listener participants and test access. Current 27.0.1/128GiB host and documentary commands establish neither baseline support nor UX. |
| Production milestones / Lead + Brandon | Separate named WW-009/M1, WW-019/M2, WW-030/M3, WW-037/M4 approvals after full prerequisites; optional WW-051 native adapter remains separate. Synthetic/finite approval and WW-004 documentary completion are **not implementation authorization**. |

Native/storage body-only hashes remain **`fe2ec212dc1601f0c87d5f1713c9264217ca72b869d77a3f7fe6749abc9ce14d`** / **`3a0af182c0a23506d5f4545bcb8cd33548cf7a66a3fd7bbdeb14203314cd5c01`**, distinct from heading-inclusive review extracts above. **STOP: final batch done.** No native/storage/speech/general validator support or production/media/model/provider permission is inferred from this documentary closure.
