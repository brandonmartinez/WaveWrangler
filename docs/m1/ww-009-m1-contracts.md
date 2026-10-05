# WW-009 — M1 selected contracts, evidence plan, risks and scope

**Record date:** 2026-10-04 · **Owner:** Lead (Lead / Product Architect) · **Issue:** [WW-009 (#3)](https://github.com/brandonmartinez/WaveWrangler/issues/3) · **Milestone:** [M1 — Durable organizer](https://github.com/brandonmartinez/WaveWrangler/milestone/1)

**Record kind:** the dated selected-contract / evidence / risk / scope record that WW-009 requires. It is **not** a second generic user approval and **does not accept any outcome**. Every "will evidence" row below is a plan; the M1 coordinator updates this record (in place, dated) with actual evidence links as work merges.

Companion records:

- [WW-003 M1 fixture permission/truth/provenance and calibration/holdout protocol](ww-003-fixture-protocol.md) and its [machine-readable registry](fixtures/m1-fixture-registry.json).
- [WW-008 internal platform, permission, privacy and rights register](ww-008-platform-register.md).
- Design-owned M1 interaction records live under `docs/m1/design/` (Design's lane; this record only points to them).

## 1. Authority

- **Engineering authorization:** the user pasted the M1 kickoff ([`docs/planning/kickoffs/m1.md`](../planning/kickoffs/m1.md)) into the M1 coordinator session on 2026-10-04. It authorizes M1 repository code, builds/tests, minimal ordinary native build/test CI, changed-manifest restores, isolated branches, commits, push, reviewed PR merges and relevant issue updates. The [milestone runbook](../planning/milestone-runbook.md) states that a pasted named kickoff grants that milestone's engineering and that WW-009/019/030/037 record contracts rather than re-asking.
- **Not authorized by that kickoff (and therefore not assumed here):** browsing/processing recordings or the optional sample folder, model downloads/native asset provisioning, provider/cloud/network trials, GUI/OS settings, signing credentials and external publishing. Each needs exact consent relayed by the coordinator (§9).
- **Superseded wording:** WW-009's original acceptance text ("Brandon authorizes WW-010–WW-012/date") is satisfied by the pasted kickoff. The *other* WW-009 conditions — WW-004–008 + WW-049 pass or explicit approved scope correction, chosen limits evidenced — are **not** satisfied by this record; they remain dependency gates on *accepting* WW-009, not on safe provisional coding behind the contracts below.

### Statement labels

| Label | Meaning |
| --- | --- |
| **F** | Fact with a cited source (repository research evidence, live issue, Apple primary document fetched 2026-10-04 or host observation). |
| **D** | Lead decision for M1; reversible only through a dated amendment to this record. |
| **A** | Working assumption; must be checked before acceptance. |
| **G** | Open gate; must be evidenced or explicitly transferred; never labelled passed without evidence. |
| **Q** | Deferred question needing coordinator/user; does not block independent work. |

## 2. M1 scope

**In scope** (kickoff items 1–7): durable show/project library and shallow sidebar; multiple episodes/metadata; durable collections, recent and unavailable entries; rebuildable derived indexes; native create/open/Save/Save As/document lifecycle, dirty state, autosave ON (default)/configurable/OFF plus explicit Save, coherent publication/recovery/migration, unknown-newer refusal, library↔project reconciliation and honest failures; cloud-hosted canonical project locations (MVP) with prior work retained through conflict/offline/cancel/retry; immutable referenced sources with logical IDs vs device-local bookmarks/location hints, explicit regrant/relink, distinct unknown/denied/missing/changed states; source availability ON (default)/configurable/OFF with accessible progress/unknown/offline/cancel/retry; episode recorder groups/channels/epochs, speakers, user-confirmed primaries/backups and correction/relink UI; native menus/panels/commands, visible focus, non-drag/numeric alternatives, keyboard and VoiceOver core workflow, 200% text/contrast/reduced motion, accessible blocked reasons/recovery.

**Excluded from M1 (D, kickoff):** decoding or reading audio content, audio analysis, alignment/clock estimation, transcription/speech models, mixing/mastering, pause cleanup, plugins/custom training, mandatory diarization, native DAW adapters, forced or portable source copies. M1 never hashes, header-reads, previews (QuickLook/thumbnail) or decodes source content. Later destinations (Alignment/Review/Export) appear only as gated destinations with an accessible reason and remedy.

## 3. Selected M1 contracts

### C1 — Document lifecycle: AppKit `NSDocument` hosting SwiftUI views (D)

- **D:** each show is an `NSDocument` subclass (one document per show, many episodes inside); window content is SwiftUI views hosted in AppKit. An `NSDocumentController` subclass may own app-wide policy (autosave setting, cadence). Domain/persistence/source logic lives in `Packages/WaveWranglerKit` (WWCore / WWPersistence / WWSources, Mac's lane) so it is testable without AppKit.
- **Why (F):** bounded native lifecycle evidence exists for NSDocument only — 17 NSDocument cases within 24 native runtime cases ([native document spike](../research/native-document-spike.md#case-accounting-and-api-provenance)); three last-edit→coherent-disk observations 0.129 / 0.293 / 0.546 s (ND13–15); stock safe publication retained in the windowed batch ([windowed spike](../research/windowed-document-spike.md#native-boundary-saved-content-and-host-qualifications)); autosave-policy-v1 AS02/AS03/AS04 pass-limited ([AS table](../research/windowed-document-spike.md#autosave-policy-v1--separate-partial-results-2026-10-04)). Apple documents the control points this contract needs: [`autosavesInPlace`](https://developer.apple.com/documentation/appkit/nsdocument/autosavesinplace), [`scheduleAutosaving()`](https://developer.apple.com/documentation/appkit/nsdocument/scheduleautosaving()), [`autosave(withImplicitCancellability:completionHandler:)`](https://developer.apple.com/documentation/appkit/nsdocument/autosave(withimplicitcancellability:completionhandler:)), [`writeSafely(to:ofType:for:)`](https://developer.apple.com/documentation/appkit/nsdocument/writesafely(to:oftype:for:)), [`isInViewingMode`](https://developer.apple.com/documentation/appkit/nsdocument/isinviewingmode), [`NSDocumentController.autosavingDelay`](https://developer.apple.com/documentation/appkit/nsdocumentcontroller/autosavingdelay) and NSFilePresenter conformance (all DocC pages fetched 2026-10-04).
- **SwiftUI `DocumentGroup` kept as alternative, not selected (D):** it compiles for target 26 and passed one serial public snapshot case, but no `DocumentGroup` scene was executed; it exposes less direct control over per-document autosave scheduling, enabled-flag boundaries, viewing mode and Close/Quit decisions; `FileDocument`/`ReferenceFileDocument` pages carry 27.2 deprecation metadata pointing to a macOS 27-gated `Document` type — a floor risk against the macOS 26+ direction, not an adoption reason ([foundation register](../research/foundation-spikes.md#lifecyclerepresentation-comparison-and-counterexamples)). **Reopen trigger:** if NSDocument subclass complexity produces unsafe save-URL handling or a DocumentGroup candidate shows equivalent evidenced control.
- **Constraints carried as contract (F → D):** a successful callback is never persistence by itself (c2 no-op autosave success without checkpoint — [native spike](../research/native-document-spike.md#architecture-recommendation-and-counterexamples)); no RunLoop sleeps or `@unchecked Sendable` workarounds count as designs; stock `writeSafely` publication is preferred — bypassing it requires a recorded reason and evidence.

### C2 — Canonical representation (D)

| Component | M1 contract | Authority / location |
| --- | --- | --- |
| Show document | One file per show: versioned envelope `{format identifier, schemaVersion, documentID, revision, payload checksum (SHA-256 over canonical payload bytes), payload}`; payload is the whole show (episodes, logical sources/hints, recorder groups/epochs/channels, speakers, primary/backup history, human corrections/comments, version records). **Integrity bookkeeping only, not authenticity.** | Canonical, cloud-hostable at a user-chosen location |
| Coherent prior checkpoint | Before each publication, the last **validated** coherent whole revision is retained as a separately identified checkpoint `{documentID, schemaVersion, revision, checksum}`. **Placement (D):** device-local recovery store inside the app container keyed by documentID (survives document move/rename on this Mac); retain at least the last two validated revisions. | Device-local recovery; never a mixture |
| Canonical library document | Separate versioned/checksummed JSON document with its own prior checkpoint: aliases, collections/order, comments, logical show references (documentID + location hints), last-known coherent revision per show, unavailable entries. **Location (D):** app container on this Mac. | Canonical for library semantics on this Mac |
| Device-local access records | sourceID/documentID → read-only security-scoped bookmark data, last resolved location, observation records. **Never** embedded in the portable show document as identity or authority. | Device-local, regenerable via regrant/relink |
| Derived index | Search/sort/lookup caches rebuilt from the library + validated show revisions; unavailable entries retained; deletion loses zero collections/corrections/comments. | Disposable |

- **Evidence for selection (F):** [project-format/recovery batch](../research/project-format-recovery.md#representation-migration-and-recovery-findings) — 6,410/6,410 assertions, 48 boundary groups × 100, 72 canonical comparisons; [native policy/library batch](../research/native-policy-library-readiness.md#actual-findings) — 53 cases incl. newer-library refusal and failed publication; Lead's [candidate recommendation](../research/project-format-recovery.md#concrete-candidate-recommendation--not-adoption) (single JSON + coherent prior + external derived caches).
- **Package not selected (D):** valid member checksums with mixed revision context (header 8/member 7) existed and needed revision-context refusal; orphans/retention untested; M1 has no large assets needing members. Reopen for M4 assets.
- **SQLite not selected as canonical (D):** main-only copying missed committed WAL revision 8 in 100/100 cases; a newly constructed adapter can fail before corrupt-header fallback; provider transport of WAL/SHM unproved. May be reconsidered only for the disposable derived index, never for canonical human work.
- **Placement tradeoff stated honestly (F/G):** the device-local prior does **not** provide cross-device recovery; if provider corruption/truncation of the current file happens on another device, recovery there depends on that device's store or provider versions. **Q1:** a portable prior (embedded or sidecar related item) is a deferred experiment — sidecars need related-item declarations under sandbox and are not atomic with the main file.
- **Q2:** the canonical library lives on this Mac in M1; a user-chosen library location (e.g., cloud folder) is deferred. Per-show human work remains cloud-canonical inside each show document, so library loss loses only library-level aliases/collections/order — recorded as residual risk R6.
- **Version records (D):** project schema, library schema, source-reference schema and access-record schema are independently versioned from day one; M2+ versions (map/model/recipe/renderer) are reserved fields only.

### C3 — Save ordering, publication and acknowledgement (D)

Ordered protocol for every explicit Save, Save As and automatic publication:

1. Snapshot the in-memory model as an immutable value with `expectedBase = {revision, checksum}`.
2. Refuse if the document is unknown-newer/read-only (C5) — before any write.
3. Encode and validate the complete candidate revision `r+1` (schema + semantic validation + checksum).
4. Retain the validated coherent prior (`r`) in the recovery store without overwriting the only recoverable copy.
5. Coordinated write (NSDocument save path / `NSFileCoordinator`): re-read on-disk base metadata; if on-disk revision/checksum ≠ `expectedBase`, stop with **Conflict** (C4), no overwrite.
6. Publish via stock safe publication (`writeSafely`) unless a recorded exception exists.
7. **Independent read-back:** coordinated read of the published bytes must parse, checksum and match `r+1` before any "Saved" state.
8. Only then acknowledge to the library/index (last-known coherent revision `r+1`).

**Acknowledgement states (D)** — distinct, accessible text, never colour only: `Edited (unsaved)` · `Saving…` · `Saved on this Mac — revision r+1 at <time>` (local coherent disk truth) · `Provider sync: unknown` (separate; never implied by a local save) · `Save failed — revision r retained` · `Conflict — another revision is on disk` · `Save may have completed — reopen to verify` (**acknowledgement-uncertain**: publication may have occurred but read-back/later steps failed) · `Recovery checkpoint on this Mac` (C6) · `Read-only — newer format`.

Any failure leaves the document dirty and does not advance the library/index; acknowledgement-uncertain requires explicit reopen/reconcile before library acknowledgement ([F: 300 serial reconciliation cases](../research/project-format-recovery.md#representation-migration-and-recovery-findings)). No step ever writes a mixed revision. Cancellation before step 6 changes nothing on disk; after step 6 it reports "revision saved, follow-up incomplete", not "nothing happened".

### C4 — Conflicts and concurrency (D)

- All windows on the same document share one `NSDocument` model and undo stack.
- Other writers (another process, another device via provider, user replacement) are detected by the base check inside the coordinated write (C3.5) and by `NSFilePresenter` change notifications/`fileModificationDate`; provider conflict versions are surfaced via [`NSFileVersion.unresolvedConflictVersionsOfItem(at:)`](https://developer.apple.com/documentation/foundation/nsfileversion/unresolvedconflictversionsofitem(at:)) as evidence only.
- Resolution choices are always non-destructive: keep mine as a new document (Save As), open theirs, compare. No automatic merge in M1.
- **F/G:** serial preflight has TOCTOU; neither coordination nor a security scope is a lock or a provider compare-and-swap ([native spike counterexamples](../research/native-document-spike.md#architecture-recommendation-and-counterexamples)). The contract narrows and detects; it does not claim atomicity.

### C5 — Migration, corruption and unknown-newer (D)

- **Known older schema:** preserve original bytes and a non-overwriting backup; decode explicitly into a staged whole new revision; keep unknown facts explicitly unknown; validate against independently specified expectations; publish only after checks; cancel/retry coherent; recovery/refusal runs before any adapter can damage the original.
- **Unknown-newer schema:** open read-only (viewing mode) with an accessible reason; edit, Save, autosave, Save As-as-downsave and migration are all refused; no fallback path may bypass the refusal.
- **Corrupt current file:** never recreate from the index; offer validated checkpoints from the recovery store **as a new copy**, keeping the suspect file untouched.
- **Library:** same rules for the library document.

### C6 — Autosave policy: ON (default) / configurable / OFF + explicit Save (D)

- **Setting:** app-level preference, default **ON**, configurable cadence from a bounded set; current state visible per document window. Explicit Save (⌘S) always works with a valid file type.
- **Mechanism:** the **actual enabled flag is consulted at the public scheduling boundary and at every queued/automatic autosave entry**. In OFF no automatic publication is scheduled; a queued automatic request that arrives after OFF completes as *not saved* (native cancellation-style non-success, never a success-shaped `nil` acknowledgement) and the document stays dirty. **Forbidden:** `autosavingFileType = nil`/empty-type disablement (UI09 failure: four continued error 1004 / Not Saved), fake success callbacks, clearing dirty state for skipped work, private hooks, deadlocking callbacks. The exact public hooks remain **unverified** until Mac evidences them.
- **Close/Quit:** dirty documents under OFF or after failed autosave still get the native Save / Don't Save / Cancel decision; no route may silently discard work.
- **Edit-to-quiescent checkpoint (ON):** provisional gate **≤2 s** from last edit to a coherent, independently read-back checkpoint on this host. The checkpoint may be the in-place canonical publication or the device-local recovery checkpoint (whichever lands first; UI names which). This is measured separately from the user's cadence; a longer configured cadence never removes the ≤2 s recovery checkpoint.
- **OFF and crash protection (D):** OFF performs no automatic writes of user work; the UI states unsaved changes are not crash-protected. **Q3:** should OFF still keep a device-local crash-recovery snapshot (not a save)? Deferred; conservative reading selected.
- **Retained open gates (G):** native OFF/nil risk (nil acknowledgement can let close paths treat autosave as completed — [native policy report](../research/native-policy-library-readiness.md#native-race-what-was-actually-established)); **AS01** queued dirty-race cancellation *unestablished* (three invalid setups); **AS05** dirty-Quit *partial* (no Quit sheet observed); stock ON cadence observed ≈5 s with 5 s setting, not ≤2 s. These stay open in WW-005/049 until new evidence; delegate-only `applicationShouldTerminate` interception is too late per Apple's [`terminate(_:)`](https://developer.apple.com/documentation/appkit/nsapplication/terminate(_:)) ordering.

### C7 — Source reference model (D)

- **Identity:** a source is a logical `SourceID` (UUID) in the show document. Name, relative path (to the document), absolute path and bookmark are **location/permission hints only, never identity**. Identity is `unverified` unless the user explicitly confirms a relink; M1 never content-hashes to establish identity. **F:** a plain bookmark resolved a *replacement* file after the original moved (`stale=true`) ([native policy report](../research/native-policy-library-readiness.md#actual-findings)) — bookmark resolution never confirms identity.
- **Independent observations**, each with `observedAt` and evidence source:

  | Dimension | Values |
  | --- | --- |
  | location | known / unresolved / candidate-moved |
  | access | granted / denied / unknown |
  | residency | local / placeholder / unknown |
  | transfer | idle / in-progress(known %) / in-progress(unknown) / failed / cancelled / unknown |
  | identity | user-confirmed / changed / unverified |

  `Denied` is never shown as `missing`. Duration/channel count are **UNKNOWN** unless safe non-content metadata supplies them; assignments made without it are labelled provisional.
- **Access lifecycle:** grant only through native panels; persisted access uses security-scoped bookmarks created **read-only** (`.withSecurityScope` + `.securityScopeAllowOnlyReadAccess`); every successful `startAccessingSecurityScopedResource()` is balanced by `stopAccessingSecurityScopedResource()` on success, error and cancel paths; scopes are held only for the operation, never as locks; stale bookmarks are refreshed only while valid access exists, otherwise the source moves to `regrant required` ([Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)).
- **Relink:** explicit, per item or batch, via native panel; confirmation shows observed differences; a same-name file at the old path is a *candidate*, never an automatic substitute.
- **Immutability:** no rename/move/delete/trash/overwrite/coordinated write against sources. Zero source writes is a test invariant (WW-006).

### C8 — Source availability: ON (default) / configurable / OFF (D)

- **ON:** for sources reporting `placeholder` residency, the app may request local availability after add/open — on iCloud Drive via [`FileManager.startDownloadingUbiquitousItem(at:)`](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:)) with progress from ubiquitous resource keys **only where the provider populates them**; otherwise `Progress unknown`. Offline/cancel/retry explicit. No generic provider classifier. OneDrive/Dropbox File Provider behavior is **UNKNOWN** until consented trials.
- **OFF / metadata-only:** zero app content reads, hashes, header reads, previews/thumbnails/QuickLook, decodes and download requests. Allowed: URL resource-value metadata queries, read-only bookmark create/resolve without mounting, coordination with [`.immediatelyAvailableMetadataOnly`](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/immediatelyavailablemetadataonly). An explicit per-item **Make Available** action remains available in OFF, clearly labelled as a content transfer.
- **Enforcement for evidence (D):** all content-capable operations pass through a single source-access gateway protocol in WWSources; tests inject a recording gateway and assert zero calls on OFF paths; a source-level check forbids content-capable APIs outside the gateway. **Limit (F):** this proves *app* requests only; OS/provider/picker activity is observed separately and never assumed absent ([research](../planning/research.md#external-sources-and-file-provider-contract)).
- Downloading a source is never permission for an agent to inspect it and never provisions models.

### C9 — Recorder groups, speakers, primaries (D, no decode)

Episode content holds recorder groups (group clock distinct from clip start), clip epochs, channels (count UNKNOWN unless safe metadata), speakers, channel→speaker assignments and a user-confirmed primary with retained backups. Each assignment is labelled `user-confirmed` or `provisional`. Changing the primary marks dependent (future) work stale; nothing is retargeted. All edits are named undoable actions with non-drag/numeric alternatives.

### C10 — Native UI/accessibility

Interaction contract is Design's ([WW-004 documentary specification](../research/foundation-spikes.md#core-task-walkthrough-contract), 18/18 core tasks, plus `docs/m1/design/`). Lead's architectural constraints: status states in C3/C6/C7/C8 are model values with accessible text; no provider I/O on the main thread; every core task has a menu/keyboard path; blocked destinations expose reason and remedy.

## 4. Acceptance evidence plan per issue

Columns: **M1 evidence → method**; **Consent-blocked** (cannot run until exact consent is relayed by the coordinator; dependent claim stays unsupported); **Transfer** (only reference-device/participant/public-artifact qualification may move to Release [WW-052 (#49)](https://github.com/brandonmartinez/WaveWrangler/issues/49) / [WW-041 (#39)](https://github.com/brandonmartinez/WaveWrangler/issues/39)). Fixture IDs refer to the [M1 registry](fixtures/m1-fixture-registry.json).

### WW-003 (#5) — fixtures and claim coverage

| Criterion (M1-applicable) | M1 evidence → method | Consent-blocked | Transfer |
| --- | --- | --- | --- |
| 100% entries permission/truth/provenance | Registry audit script (Pipeline/Lead) + review → every entry complete | — | — |
| Cloud canonical saves/conflicts/autosave/recovery/offline/cancel strata | `M1-DUR-*` synthetic families, frozen before holdout | Real provider strata `M1-DUR-024/025` | — |
| Separate default-OFF metadata vs default-ON source trials | `M1-SRC-OFF-*` vs `M1-SRC-ON-*` (synthetic double), separately labelled | Real provider ON trials `M1-SRC-ON-PROV-*` | — |
| Keyboard/VoiceOver strata | `M1-A11Y-*` task suite defined | GUI/VoiceOver/OS settings runs | Broader participant studies → WW-052 |
| Versions, holdout split/counts, controlled pre-holdout calibration | Freeze record per family before holdout | — | — |
| Later M2–M4 strata (clock, edit, speech, import, export, listening) | **Not M1**; pointers in registry to WW-015–018/050, 025–029/043–046, 035–038 | — | Domain issues (not Release) |

### WW-005 (#6) and WW-049 (#44) — durability and cloud consistency

| Criterion | M1 evidence → method | Consent-blocked | Transfer |
| --- | --- | --- | --- |
| Compare package/JSON/SQLite, in-memory snapshots/cadence, NSDocument+SwiftUI vs SwiftUI lifecycle | C1/C2 rationale + cited research; selected contracts recorded here | — | — |
| Autosave ON/configurable/OFF + explicit Save | WWPersistence/app policy tests (enabled-flag boundaries, queued request after OFF, OFF→ON with pending edits); `M1-DUR-002..005` | Native GUI Close/Quit dirty decisions (AS01/AS05 replays, `M1-DUR-026`) need GUI-launch consent | — |
| ≥100 interruptions at **each** publication boundary; old valid or coherent checkpoint, never mixed | `M1-DUR-006`: 7 boundaries × 100 holdout (injected) + `M1-DUR-021` owned-subprocess kill × 100 per boundary | Power loss; provider-sync boundary | — |
| Concurrent saves/conflicts | `M1-DUR-007..009` (external writer, same-document windows, two processes) | Two-device/provider conflicts `M1-DUR-024/025` | — |
| Offline/cancel/retry/disk-full/Save As | `M1-DUR-010..014` (ENOSPC injected; programmatic cancel) | Real full-volume variant (disk image) needs coordinator confirmation; native save-panel cancel needs GUI consent | — |
| Library reconciliation; acknowledgement uncertainty | `M1-DUR-015, 019` | — | — |
| Quiescent checkpoint ≤2 s provisional (ON) | `M1-DUR-002` timing on claimed host, p95 and max reported | — | macOS 26/16 GB confirmation → WW-052 |
| Unknown-newer refuses edit/save/downsave | `M1-DUR-018, 022` (100% of cases) | — | — |
| Corrupt migration retains prior valid revision | `M1-DUR-016, 017, 023` | — | — |
| Index rebuild loses zero semantic collections/corrections | `M1-DUR-020` | — | — |
| No lock/atomicity inference; simulated vs observed provider guarantees reported | Record wording; every provider claim marked simulated unless `M1-DUR-024` ran | Provider trials | — |

### WW-006 (#1) — immutable references, relink, source availability

| Criterion | M1 evidence → method | Consent-blocked | Transfer |
| --- | --- | --- | --- |
| ≥1,000 lifecycle/error/cancel cases, zero leaked scopes/source writes/substitutions | `M1-REF-001..017` holdout sum 1,110 (≥1,000); scope-balance counter (`M1-REF-016`) + before/after harness digests of generated sources (`M1-REF-018`) | — | — |
| Stale refresh vs regrant; moved/copied relink; bookmark/path ≠ identity | `M1-REF-002..007` (incl. substitution counterexample) | Real sandboxed panel grant/regrant (`M1-REF-020`) needs GUI consent | — |
| Cross-machine relink | Synthetic: missing access record → `relink required` (`M1-REF-017`) | Real second device | — |
| Default-OFF metadata: zero app content/hash/header/preview/decode/download | `M1-SRC-OFF-*` gateway spy + forbidden-API check | — | — |
| Default-ON: progress/unknown/offline/cancel/retry, accessible off control | `M1-SRC-ON-*` synthetic double | Real iCloud/OneDrive/Dropbox (`M1-SRC-ON-PROV-*`) | — |
| Independent dimensions; denied ≠ missing; duration/channel UNKNOWN | Model + UI-state tests (`M1-REF-008/009/019`) | — | — |

### WW-007 (#8) — responsiveness and core accessibility

| Criterion | M1 evidence → method | Consent-blocked | Transfer |
| --- | --- | --- | --- |
| p95 open <1 s / interaction <100 ms (provisional) | `M1-SCALE-001` on claimed host (100 projects/1,000 refs), cold/warm separately | — | **Actual macOS 26/16 GB reference → WW-052** |
| No main-thread provider I/O | Main-thread assertion in gateway + test | — | — |
| 100% core M1 keyboard/VoiceOver tasks (save/conflict/autosave ON/OFF/explicit Save; source ON/OFF/unknown/offline/cancel/retry) | `M1-A11Y-001/002` suite; static accessibility label/identifier audit (`M1-A11Y-004`, not a VoiceOver result) | **GUI launch/UI tests and VoiceOver runs pending user answer** | Broader participant studies → WW-052 |
| Cold/warm/recovery/200% text/contrast/reduced-motion | `M1-A11Y-003` | OS setting changes pending user answer | Reference device → WW-052 |

### WW-008 (#7) — platform register

See [register](ww-008-platform-register.md#11-acceptance-mapping). Signed/notarized/clean-install/grant/relaunch proof → WW-041/052; current-milestone register content and safe internal envelope stay M1.

### WW-010 (#4), WW-011 (#2), WW-012 (#9) — implementation

| Issue | M1 evidence → method | Consent-blocked | Transfer |
| --- | --- | --- | --- |
| WW-010 | C1–C6 implemented in WWPersistence + app; golden synthetic migration/corruption/interruption/concurrent-window/disk-full/Save As/reconciliation cases (`M1-DUR-*`); reference schema versioned; zero index semantic loss | Provider/GUI as above | — |
| WW-011 | Library/sidebar/episode workspace; collections/recent/unavailable; status distinct from index; `M1-SCALE-001`; save/reopen/index-rebuild consistency | Native keyboard/VoiceOver task runs (GUI) | Reference device → WW-052 |
| WW-012 | C7–C9; group/epoch/channel/speaker/primary correction; non-drag/numeric/named undo; source ON/OFF; `M1-REF-*`, `M1-SRC-*`; manual validation with the user-provided disposable episode copy (`M1-USER-001`, manual only) | Real provider matrix; GUI runs | — |

### WW-013 (#12) — M1 acceptance (Lead)

End-to-end authorized synthetic task/recovery run plus the coordinator's M1 exit record. Acceptance requires every row above evidenced or carrying an explicit approved transfer with a linked receiving issue. Consent-blocked rows that leave a **core** workflow unsupported (e.g., GUI keyboard/VoiceOver verification) cannot be transferred to manufacture completion; they require the consent or an approved scope correction.

## 5. Frozen numeric gates (preserved verbatim, not re-tuned)

| Gate | Value | Issue |
| --- | --- | --- |
| Edit-to-quiescent coherent checkpoint | **≤2 s provisional**, not an autosave-cadence claim | WW-005 |
| Publication-boundary interruptions | **≥100 per boundary**; zero mixed revisions / silent lost edits / source mutation | WW-005, WW-049 |
| Unknown-newer | **100%** refuse edit/save/downsave | WW-005 |
| Index rebuild | **zero** semantic collections/corrections lost | WW-005 |
| Reference lifecycle | **≥1,000** lifecycle/error/cancel cases; **zero** leaked scopes / source writes / substitutions | WW-006 |
| Metadata-only OFF | **zero** app content/hash/header/preview/decode/download requests | WW-006, WW-012 |
| Responsiveness | p95 open **<1 s**, interaction **<100 ms** (provisional; claimed host now, reference later) | WW-007 |
| Scale | **100 projects / 1,000 references** | WW-007, WW-011 |
| Core accessibility | **100%** core M1 keyboard/VoiceOver tasks | WW-007 |
| Fixture registry | **100%** entries with permission/truth/provenance | WW-003 |

## 6. Retained failures and later-domain evidence (not fixed, not hidden)

| Retained item | Disposition | Owner issue |
| --- | --- | --- |
| **2/6 acoustic clock negatives falsely accepted** | WW-016 candidate FAIL retained; M2 evidence, not M1 | [WW-016 (#15)](https://github.com/brandonmartinez/WaveWrangler/issues/15) |
| **Native OFF/nil risk**; UI09 four error-1004/Not Saved; c2 no-op success | **Open M1 gate** under C6; nil acknowledgement not adopted | WW-005 (#6), WW-049 (#44) |
| AS01 unestablished, AS05 partial dirty-Quit | Open M1 gates | WW-005, WW-049 |
| Stock ON ≈5 s (configured 5 s), not ≤2 s | Historical; ≤2 s gate unchanged | WW-005 |
| **Unexecuted merged-fade final-footprint risk** | M3/M4 evidence | [WW-028 (#25)](https://github.com/brandonmartinez/WaveWrangler/issues/25), [WW-036 (#34)](https://github.com/brandonmartinez/WaveWrangler/issues/34), [WW-043 (#40)](https://github.com/brandonmartinez/WaveWrangler/issues/40) |
| **WhisperKit tokenizer network fallback** despite `download:false` | M3 fail-closed requirement | [WW-026 (#23)](https://github.com/brandonmartinez/WaveWrangler/issues/23) |
| SQLite main-only WAL miss (100/100); constructor-before-recovery deficit | Reason SQLite is not canonical | WW-005 |
| Bookmark resolves replacement (`stale=true`) | Reason bookmark ≠ identity (C7) | WW-006 |
| Historical baselines: 400 incoherent publications, 300 stale-writer losses, 40/40 acoustic-only false accepts | Negative controls, historical | WW-049 / WW-016 |

## 7. Risks (M1)

| ID | Risk | Mitigation / gate |
| --- | --- | --- |
| R1 | Provider (iCloud/OneDrive/Dropbox) publication not atomic; remote writer may interleave | C3/C4 detection; acknowledgement-uncertain state; consented provider trials `M1-DUR-024`; claims stay "simulated" until then |
| R2 | OFF autosave hook legality on AppKit unverified | C6 forbids nil/empty type; Mac evidences public hooks; AS01/AS05 stay open |
| R3 | Sandbox + security-scoped bookmark behavior unevidenced on this app | WW-008 register; `M1-REF-020` needs GUI consent for panel grants; programmatic subsets first |
| R4 | GUI keyboard/VoiceOver verification blocked on consent | Static AX checks and model-level tests proceed; core-workflow acceptance waits on consent |
| R5 | Device-local prior gives no cross-device recovery | Stated limit; Q1 experiment |
| R6 | Library device-local; container loss loses aliases/collections | Library prior checkpoint; Q2 deferred location option; show documents remain canonical |
| R7 | Claimed host far exceeds reference (128 GiB vs 16 GB) | Measurements labelled claimed-host only; WW-052 |
| R8 | Metadata-only proof covers app requests, not OS/provider work | Gateway spy + forbidden-API check; limit stated |

## 8. Deferred questions

- **Q1** Portable (cross-device) prior checkpoint placement (embedded vs sidecar related item) — experiment later.
- **Q2** User-chosen canonical library location (cloud folder) vs this-Mac container.
- **Q3** Device-local crash snapshot while autosave is OFF.
- **Q4** Exact consents (§9) for GUI launch/UI tests, VoiceOver, OS display settings, provider trials and a second device.

## 9. Consent ledger (as known to Lead on 2026-10-04)

| Activity | Status |
| --- | --- |
| Synthetic generated fixtures in temp dirs, unit/integration tests, `xcodebuild`/`swift test` | **Authorized** (kickoff) |
| Ad-hoc local signing ("Sign to Run Locally") | Authorized for builds; no credentials |
| User-provided local disposable episode copy (path withheld) | **Consent relayed by M1 coordinator** — manual M1 import/library/recorder-grouping/primary-backup/relink validation only, read-only, no decode/analysis/transcription, never in automated tests or repo (`M1-USER-001`). Lead has not seen the original user message. |
| GUI app launch / XCUITest / VoiceOver / OS accessibility settings | **Pending user answer** |
| Real iCloud/OneDrive/Dropbox writes, network trials, two-device | **Not authorized** |
| Recording/sample-folder browsing, model downloads, signing credentials, publishing | **Not authorized** |

## 10. Change log

- 2026-10-04 — Initial record (Lead). Contracts selected; no outcome accepted.
