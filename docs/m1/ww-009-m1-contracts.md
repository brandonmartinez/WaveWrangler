# WW-009 — M1 selected contracts, evidence plan, risks and scope

**Record date:** 2026-10-04 · **Owner:** Lead (Lead / Product Architect) · **Issue:** [WW-009 (#3)](https://github.com/brandonmartinez/WaveWrangler/issues/3) · **Milestone:** [M1 — Durable organizer](https://github.com/brandonmartinez/WaveWrangler/milestone/1)

**Record kind:** the dated selected-contract / evidence / risk / scope record that WW-009 requires. It is **not** a second generic user approval and **does not accept any outcome**. Every "will evidence" row below is a plan; the M1 coordinator updates this record (in place, dated) with actual evidence links as work merges.

Companion records:

- [WW-003 M1 fixture permission/truth/provenance and calibration/holdout protocol](ww-003-fixture-protocol.md) and its [machine-readable registry](fixtures/m1-fixture-registry.json).
- [WW-008 internal platform, permission, privacy and rights register](ww-008-platform-register.md).
- Design-owned M1 interaction records live under `docs/m1/design/` (Design's lane; this record only points to them).

## 1. Authority

- **Engineering authorization:** the user pasted the M1 kickoff ([`docs/planning/kickoffs/m1.md`](../planning/kickoffs/m1.md)) into the M1 coordinator session on 2026-10-04. It authorizes M1 repository code, builds/tests, minimal ordinary native build/test CI, changed-manifest restores, isolated branches, commits, push, reviewed PR merges and relevant issue updates. The [milestone runbook](../planning/milestone-runbook.md) states that a pasted named kickoff grants that milestone's engineering and that WW-009/019/030/037 record contracts rather than re-asking.
- **Not authorized by that kickoff (and therefore not assumed here):** browsing/processing recordings or the optional sample folder, model downloads/native asset provisioning, provider/cloud/network trials, GUI/OS settings, signing credentials and external publishing. Each needs exact consent relayed by the coordinator (§9). **Later user grants (2026-10-04, relayed by the coordinator):** A (GUI/XCUITest/accessibility audits/computer-use under a single GUI lock), B (temporary VoiceOver), C (one iCloud Drive synthetic trial folder) and D (temporary contrast/motion/text settings) — exact scopes in §9. Second device, OneDrive, Dropbox and disk-image tests remain unauthorized.
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
| Unpublished edit-checkpoint record | Defined in **C2b**: a whole-model snapshot of not-yet-published edits, explicitly `unpublished`, never a revision or a save. | Device-local recovery store |
| Canonical library document | Separate versioned/checksummed JSON document with its own prior checkpoint: aliases, collections/order, comments, logical show references (documentID + location hints), last-known coherent revision per show, unavailable entries. **Location (D, coordinator decision 2026-10-04): configurable** — defaults to the app container; the user may choose a folder (e.g., iCloud Drive/OneDrive/Dropbox) via a native panel (**C2a**). Same C3–C5 rules as show documents. | Canonical; cloud-hostable at a user-chosen folder |
| Device-local access records | **Two bookmark modes (D):** source references → **read-only** security-scoped bookmarks (`.securityScopeAllowOnlyReadAccess`); show documents (library/recent entries) and the chosen library folder → **read-write** security-scoped bookmarks. Plus last resolved location and observation records. **Never** embedded in the portable show document as identity or authority. | Device-local, regenerable via regrant/relink |
| Derived index | Search/sort/lookup caches rebuilt from the library + validated show revisions; unavailable entries retained; deletion loses zero collections/corrections/comments. | Disposable |

- **Evidence for selection (F):** [project-format/recovery batch](../research/project-format-recovery.md#representation-migration-and-recovery-findings) — 6,410/6,410 assertions, 48 boundary groups × 100, 72 canonical comparisons; [native policy/library batch](../research/native-policy-library-readiness.md#actual-findings) — 53 cases incl. newer-library refusal and failed publication; Lead's [candidate recommendation](../research/project-format-recovery.md#concrete-candidate-recommendation--not-adoption) (single JSON + coherent prior + external derived caches).
- **Package not selected (D):** valid member checksums with mixed revision context (header 8/member 7) existed and needed revision-context refusal; orphans/retention untested; M1 has no large assets needing members. Reopen for M4 assets.
- **SQLite not selected as canonical (D):** main-only copying missed committed WAL revision 8 in 100/100 cases; a newly constructed adapter can fail before corrupt-header fallback; provider transport of WAL/SHM unproved. May be reconsidered only for the disposable derived index, never for canonical human work.
- **Placement tradeoff stated honestly (F/G):** the device-local prior does **not** provide cross-device recovery; if provider corruption/truncation of the current file happens on another device, recovery there depends on that device's store or provider versions. **Q1:** a portable prior (embedded or sidecar related item) is a deferred experiment — sidecars need related-item declarations under sandbox and are not atomic with the main file.
- **Library location is not deferred (D, replaces former Q2):** a container-only canonical library would be a local-only substitute, contrary to accepted policy ([project-format recovery](../research/project-format-recovery.md#concrete-candidate-recommendation--not-adoption): "A device-local SQLite library cannot silently replace required cloud-canonical human work"; WW-010 "cloud canonical project/library storage"). See C2a.
- **Version records (D):** project schema, library schema, source-reference schema and access-record schema are independently versioned from day one; M2+ versions (map/model/recipe/renderer) are reserved fields only.

#### C2a — Library location (D)

- **Default:** app container (works with no grant). **User choice:** Settings/File command → native `NSOpenPanel` folder selection (any user-chosen folder, including iCloud Drive/OneDrive/Dropbox locations). The app persists a **read-write** security-scoped bookmark to that folder in device-local preferences; the library file inside it is published with the full C3 order (coordinated publication, base check, read-back), C4 conflict handling, C5 unknown-newer refusal and a validated prior checkpoint.
- **Move/relocate:** (1) validate current library; (2) copy it to the destination with coordinated write; (3) independent read-back verifies the copy (checksum/revision/payload); (4) switch the location bookmark; (5) only then **retire** the old copy. *Amended 2026-10-05 (coordinator decision; Design ST-33):* "retire" means WaveWrangler stops reading and writing the old copy and **keeps it where it is as a backup; it is never deleted**. Any failure before (4) leaves the old location authoritative and reports the failure, leaving any partial copy in place. *Amended 2026-10-05 (coordinator decision; Design ST-33 step 6 and ST-36):* if a library already exists at the destination, the app checks its state without writing; when it is ready, **Use That Library** combines both libraries by the ST-36 rule (union by identity, nothing dropped, differing same-name collections kept with "(from this Mac)" suffixes), verifies the combined library, then retires the current one as a backup. Unreachable, needs-permission or newer-format destinations get no write. (Superseded wording: "retained as a prior checkpoint … before being removed from the old location"; "a failure after (4) reports 'moved; old copy not yet retired' with retry"; "*open that library* or *keep mine* (conflict, no merge, no overwrite)".)
- **Unavailable location:** if the bookmark is stale/denied/offline, the library is shown from the last verified copy (labelled), with regrant/retry; it is never silently replaced by a new empty container library. *Amended 2026-10-05 (coordinator decision):* in L2 (unreachable) and L3 (needs permission), library edits are **queued** in a durable device-local journal ("Edits waiting"), replayed through the C3 base check when the location is reachable again, three-way merged on divergence, routed to L4 when a change can't be carried, and cleared only after verified publication. Grant Access accepts a folder only when it holds the same library by `libraryID` (library schema 2). (Superseded wording: "shown read-only from the last validated prior".)
- **Residual risk R6:** applies only while the container default is in use; the UI shows visible status ("Library stored on this Mac only") with a Move Library command.

#### C2b — Unpublished edit-checkpoint record (D)

- **Purpose:** satisfies the ON-mode ≤2 s edit-to-quiescent checkpoint (C6, `M1-DUR-002`) without pretending to be a save, and enables recovery after crash/kill when canonical publication has not happened.
- **Record:** `{recordKind: "edit-checkpoint", documentID, baseRevision, baseChecksum, checkpointSequence (monotonic per document), createdAt, schemaVersion, unpublished: true, payloadChecksum, payload (whole model snapshot)}`. Written atomically (stage + verify + replace) to the device-local recovery store, separate from published prior checkpoints. Never written to the canonical location, never advances library/index, never clears dirty state, never shown as "Saved".
- **Created:** ON only, **at quiescence** (the moment the edit burst settles, not after any deadline). It is written whenever a read-back-verified canonical publication is not expected to complete before the ≤2 s deadline with a **≥0.5 s safety margin**, that is, by 1.5 s after the last edit. This covers three cases: the configured autosave cadence is longer than about 1.5 s; no publication is in flight or scheduled; or the in-flight publication has failed or is acknowledgement-uncertain. If a verified publication lands first, the record is unnecessary and is pruned. The **≤2 s gate is unchanged**. `M1-DUR-002` measures whichever coherent checkpoint is verified first and fails any case where neither is verified within 2 s. **OFF creates none** (C6, Q3).
- **Retention:** latest record per document plus the immediately previous one until the newer is read-back verified. Deleted when (a) a published revision containing all its edits is read-back verified, or (b) the user explicitly chooses Don't Save/Discard for that document. No age-based automatic deletion in M1; stale records are presented, not purged.
- **Recovery presentation:** on open/relaunch, if a record exists — `baseRevision` == on-disk revision → offer "Restore unsaved changes from <time>" (restored document is **dirty, not saved**); `baseRevision` ≠ on-disk revision → "Unsaved changes based on an older revision" → open as a separate untitled copy or compare; never auto-merge or auto-publish. Corrupt/unknown-newer records are reported and retained, never applied.
- **Close/Quit:** with ON, Close/Quit attempts canonical publication; if it fails, the native Save / Don't Save / Cancel decision appears and the edit checkpoint remains. A record's existence never suppresses the decision. With OFF, the decision always appears for dirty documents.

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

**Interruption boundaries derived from this order (D; used by `M1-DUR-006/021`):**

| Boundary | After → before | Public injection point | Paths evidenced |
| --- | --- | --- | --- |
| P1 | step 3 candidate validated → step 4 prior retained | publisher step hook; NSDocument: our `writeSafely(to:ofType:for:)` override before calling `super` | publisher + NSDocument |
| P2 | step 4 prior retained → step 5 coordinated write/base check | publisher hook; NSDocument: `writeSafely` override before `super`, after retention | publisher + NSDocument |
| P3 | step 5 base check passed → step 6 bytes written | publisher: `NSFileCoordinator` writing accessor; NSDocument: throw from our `write(to:ofType:for:originalContentsURL:)` override before writing | publisher + NSDocument |
| P4 | step 6 staged bytes written/flushed → canonical replace | publisher only (stage → `replaceItemAt`) | **publisher only** |
| P5 | step 6 publication returned → step 7 read-back | publisher hook; NSDocument: `writeSafely` override after `super` returns | publisher + NSDocument |
| P6 | step 7 read-back verified → step 8 library ack | save-completion handler before library ack | publisher + NSDocument |
| P7 | step 8 library ack → derived index update | index updater entry | publisher + NSDocument |

**What the NSDocument path does and does not evidence (F/G):** P1–P3 and P5–P7 are deterministic on both paths through public overrides. **No public hook exists inside AppKit's `writeSafely` replace**, so P4 is deterministic only in the WWPersistence-level publisher; on the NSDocument path it is reached only by non-deterministic process kill (`M1-DUR-021` random-point set), and claims are limited to "AppKit stock safe-save, not independently interrupted". The exact base-check mechanism inside AppKit's coordinated save (step 5) is **U** until Mac evidences it without nested-coordination deadlock.

**Library publication** (library is not an `NSDocument`; it uses the WWPersistence publisher) has boundaries **L1** candidate validated → prior retained, **L2** prior retained → coordinated write, **L3** base check passed (coordinator accessor) → stage write, **L4** stage flushed → `replaceItemAt`, **L5** publish returned → read-back, **L6** read-back verified → index update. Each has ≥100 injected holdout cases per location stratum (`M1-DUR-027`) and ≥100 process-kill cases (`M1-DUR-028`).

**Acknowledgement states (D)** — distinct, accessible text, never colour only: `Edited (unsaved)` · `Saving…` · `Saved on this Mac — revision r+1 at <time>` (local coherent disk truth) · `Provider sync: unknown` (separate; never implied by a local save) · `Save failed — revision r retained` · `Conflict — another revision is on disk` · `Save may have completed — reopen to verify` (**acknowledgement-uncertain**: publication may have occurred but read-back/later steps failed) · `Unsaved changes protected on this Mac (checkpoint <time>) — not saved` (C2b edit checkpoint) · `Read-only — newer format`.

Any failure leaves the document dirty and does not advance the library/index; acknowledgement-uncertain requires explicit reopen/reconcile before library acknowledgement ([F: 300 serial reconciliation cases](../research/project-format-recovery.md#representation-migration-and-recovery-findings)). No step ever writes a mixed revision. Cancellation before step 6 changes nothing on disk; after step 6 it reports "revision saved, follow-up incomplete", not "nothing happened".

### C4 — Conflicts and concurrency (D)

- All windows on the same document share one `NSDocument` model and undo stack.
- Other writers (another process, another device via provider, user replacement) are detected by the base check inside the coordinated write (C3.5) and by `NSFilePresenter` change notifications/`fileModificationDate`; provider conflict versions are surfaced via [`NSFileVersion.unresolvedConflictVersionsOfItem(at:)`](https://developer.apple.com/documentation/foundation/nsfileversion/unresolvedconflictversionsofitem(at:)) as evidence only.
- Resolution choices are always non-destructive: keep mine as a new document (Save As), open theirs, compare. No automatic merge of **show documents** in M1. *Amended 2026-10-05 (coordinator decisions):* the **library** is the exception — L4 offers Combine (Keep Everything) by the ST-36 rule (default) or Use Other Mac's Version (this Mac's version kept as a backup), and replay of queued L2/L3 edits uses a verified three-way merge that never silently drops a change.
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
- **Edit-to-quiescent checkpoint (ON):** provisional gate **≤2 s** from last edit to a coherent, independently read-back checkpoint on this host. The checkpoint may be the in-place canonical publication or the unpublished edit-checkpoint record (C2b) — whichever lands first; the UI names which, and an edit checkpoint is never "Saved". This is measured separately from the user's cadence; a longer configured cadence never removes the ≤2 s recovery checkpoint.
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
- **Access lifecycle:** grant only through native panels; persisted **source** access uses security-scoped bookmarks created **read-only** (`.withSecurityScope` + `.securityScopeAllowOnlyReadAccess`), while show documents and the library folder use **read-write** security-scoped bookmarks (`.withSecurityScope` only) so they can be reopened from the library after relaunch and saved (`M1-DUR-029`, `M1-REF-020`); a source scope is never used for writing; every successful `startAccessingSecurityScopedResource()` is balanced by `stopAccessingSecurityScopedResource()` on success, error and cancel paths; scopes are held only for the operation, never as locks; stale bookmarks are refreshed only while valid access exists, otherwise the source moves to `regrant required` ([Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)).
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

Columns: **M1 evidence → method**; **Consent / still blocked** (user grants A–D of 2026-10-04 per §9 enable the named runs; anything listed as blocked cannot run until further exact consent, and its dependent claim stays unsupported); **Transfer** (only reference-device/participant/public-artifact qualification may move to Release [WW-052 (#49)](https://github.com/brandonmartinez/WaveWrangler/issues/49) / [WW-041 (#39)](https://github.com/brandonmartinez/WaveWrangler/issues/39)). Fixture IDs refer to the [M1 registry](fixtures/m1-fixture-registry.json).

### WW-003 (#5) — fixtures and claim coverage

| Criterion (M1-applicable) | M1 evidence → method | Consent / still blocked | Transfer |
| --- | --- | --- | --- |
| 100% entries permission/truth/provenance | Registry audit script (Pipeline/Lead) + review → every entry complete | — | — |
| Cloud canonical saves/conflicts/autosave/recovery/offline/cancel strata | `M1-DUR-*` synthetic families, frozen before holdout; iCloud Drive trial `M1-DUR-024` (grant C) | Blocked: OneDrive/Dropbox `M1-DUR-030`, second device `M1-DUR-025` | — |
| Separate default-OFF metadata vs default-ON source trials | `M1-SRC-OFF-*` vs `M1-SRC-ON-*` (synthetic double), separately labelled; real iCloud OFF/ON subsets `M1-SRC-ON-PROV-001` (grant C) | Blocked: OneDrive/Dropbox `M1-SRC-ON-PROV-002/003` | — |
| Keyboard/VoiceOver strata | `M1-A11Y-001..004` (grants A, B, D for 001–003) | — | Broader participant studies → WW-052 |
| Versions, holdout split/counts, controlled pre-holdout calibration | Freeze record per family before holdout | — | — |
| Later M2–M4 strata (clock, edit, speech, import, export, listening) | **Not M1**; pointers in registry to WW-015–018/050, 025–029/043–046, 035–038 | — | Domain issues (not Release) |

### WW-005 (#6) and WW-049 (#44) — durability and cloud consistency

| Criterion | M1 evidence → method | Consent / still blocked | Transfer |
| --- | --- | --- | --- |
| Compare package/JSON/SQLite, in-memory snapshots/cadence, NSDocument+SwiftUI vs SwiftUI lifecycle | C1/C2 rationale + cited research; selected contracts recorded here | — | — |
| Autosave ON/configurable/OFF + explicit Save | WWPersistence/app policy tests (enabled-flag boundaries, queued request after OFF, OFF→ON with pending edits); `M1-DUR-002..005`; native GUI Close/Quit dirty decisions, AS01/AS05 replays and edit-checkpoint restore `M1-DUR-026` (grant A) | — | — |
| ≥100 interruptions at **each** publication boundary; old valid or coherent checkpoint, never mixed | Show document: `M1-DUR-006` P1–P7 × 100 holdout per applicable path (C3 table; P4 publisher-only) + `M1-DUR-021` process kill × 100 per boundary. Library: `M1-DUR-027` L1–L6 × 100 per location stratum + `M1-DUR-028` kill × 100 per boundary | Blocked: power loss; uncontrollable provider-sync boundaries reported as observed in `M1-DUR-024`, not claimed | — |
| Concurrent saves/conflicts | `M1-DUR-007..009` (external writer, same-document windows, two processes); iCloud two-window/two-process conflicts in `M1-DUR-024` (grant C) | Blocked: second device `M1-DUR-025`, OneDrive/Dropbox `M1-DUR-030` | — |
| Offline/cancel/retry/disk-full/Save As | `M1-DUR-010..014` (ENOSPC injected; programmatic cancel); native save-panel cancel in `M1-DUR-026` (grant A) | Blocked: real full-volume disk-image variant (not granted) | — |
| Library reconciliation; acknowledgement uncertainty; library at a user-chosen location (C2a) | `M1-DUR-015, 019` (both location strata), `M1-DUR-027/028`, library-at-iCloud case in `M1-DUR-024` (grant C); reopen-from-library-then-save `M1-DUR-029` | — | — |
| Quiescent checkpoint ≤2 s provisional (ON) | `M1-DUR-002` timing on claimed host, p95 and max reported | — | macOS 26/16 GB confirmation → WW-052 |
| Unknown-newer refuses edit/save/downsave | `M1-DUR-018, 022` (100% of cases; library in both location strata) | — | — |
| Corrupt migration retains prior valid revision | `M1-DUR-016, 017, 023` | — | — |
| Index rebuild loses zero semantic collections/corrections | `M1-DUR-020` | — | — |
| No lock/atomicity inference; simulated vs observed provider guarantees reported | Record wording; iCloud Drive claims are "observed on this Mac" only after `M1-DUR-024`; all other providers stay simulated | Blocked: OneDrive/Dropbox/second device | — |

### WW-006 (#1) — immutable references, relink, source availability

| Criterion | M1 evidence → method | Consent / still blocked | Transfer |
| --- | --- | --- | --- |
| ≥1,000 lifecycle/error/cancel cases, zero leaked scopes/source writes/substitutions | `M1-REF-001..017` holdout sum 1,110 (≥1,000); scope-balance counter (`M1-REF-016`) + before/after harness digests of generated sources (`M1-REF-018`) | — | — |
| Stale refresh vs regrant; moved/copied relink; bookmark/path ≠ identity | `M1-REF-002..007` (incl. substitution counterexample); sandboxed panel grant/regrant/relaunch with read-only source vs read-write document/library-folder bookmarks `M1-REF-020` (grant A); `M1-DUR-029` | — | Developer ID/notarized grant → WW-041 |
| Cross-machine relink | Synthetic: missing access record → `relink required` (`M1-REF-017`) | Real second device | — |
| Default-OFF metadata: zero app content/hash/header/preview/decode/download | `M1-SRC-OFF-*` gateway spy + forbidden-API check | — | — |
| Default-ON: progress/unknown/offline/cancel/retry, accessible off control | `M1-SRC-ON-001/002` synthetic double; real iCloud Drive `M1-SRC-ON-PROV-001` (grant C, brctl evict/download) | Blocked: OneDrive/Dropbox `M1-SRC-ON-PROV-002/003` | — |
| Independent dimensions; denied ≠ missing; duration/channel UNKNOWN | Model + UI-state tests (`M1-REF-008/009/019`) | — | — |

### WW-007 (#8) — responsiveness and core accessibility

| Criterion | M1 evidence → method | Consent / still blocked | Transfer |
| --- | --- | --- | --- |
| p95 open <1 s / interaction <100 ms (provisional) | `M1-SCALE-001` on claimed host (100 projects/1,000 refs), cold/warm separately | — | **Actual macOS 26/16 GB reference → WW-052** |
| No main-thread provider I/O | Main-thread assertion in gateway + test | — | — |
| 100% core M1 keyboard/VoiceOver tasks (save/conflict/autosave ON/OFF/explicit Save; source ON/OFF/unknown/offline/cancel/retry) | Keyboard suite + Xcode accessibility audits `M1-A11Y-001` (grant A); VoiceOver suite `M1-A11Y-002` (grant B); static audit `M1-A11Y-004` (not a VoiceOver result) | — | Broader participant studies → WW-052 |
| Cold/warm/recovery/200% text/contrast/reduced-motion | `M1-A11Y-003` (grant D; original OS values recorded and restored) | — | Reference device → WW-052 |

### WW-008 (#7) — platform register

See [register](ww-008-platform-register.md#11-acceptance-mapping). Signed/notarized/clean-install/grant/relaunch proof → WW-041/052; current-milestone register content and safe internal envelope stay M1.

### WW-010 (#4), WW-011 (#2), WW-012 (#9) — implementation

| Issue | M1 evidence → method | Consent / still blocked | Transfer |
| --- | --- | --- | --- |
| WW-010 | C1–C6 (incl. C2a library location, C2b edit checkpoints) implemented in WWPersistence + app; golden synthetic migration/corruption/interruption/concurrent-window/disk-full/Save As/reconciliation cases (`M1-DUR-*`); reference schema versioned; zero index semantic loss | Blocked parts as above | — |
| WW-011 | Library/sidebar/episode workspace; collections/recent/unavailable; status distinct from index; `M1-SCALE-001`; save/reopen/index-rebuild consistency | Keyboard/VoiceOver runs via grants A/B (`M1-A11Y-001/002`) | Reference device → WW-052 |
| WW-012 | C7–C9; group/epoch/channel/speaker/primary correction; non-drag/numeric/named undo; source ON/OFF; `M1-REF-*`, `M1-SRC-*`; manual validation with the user-provided disposable episode copy (`M1-USER-001`, manual only) | Blocked: OneDrive/Dropbox/second device | — |

### WW-013 (#12) — M1 acceptance (Lead)

End-to-end authorized synthetic task/recovery run plus the coordinator's M1 exit record. Acceptance requires every row above evidenced or carrying an explicit approved transfer with a linked receiving issue. Granted runs (A–D) must actually execute and pass; they are not transferable. Still-blocked rows (second device, OneDrive/Dropbox, disk image) must be reported as unsupported claims — if any of them leaves a **core** workflow unsupported, it cannot be transferred to manufacture completion and requires consent or an approved scope correction.

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
| R1 | Provider (iCloud/OneDrive/Dropbox) publication not atomic; remote writer may interleave | C3/C4 detection; acknowledgement-uncertain state; iCloud Drive trial `M1-DUR-024` (grant C) yields observed single-Mac evidence only; OneDrive/Dropbox/two-device stay simulated |
| R2 | OFF autosave hook legality on AppKit unverified | C6 forbids nil/empty type; Mac evidences public hooks; AS01/AS05 stay open |
| R3 | Sandbox + security-scoped bookmark behavior (read-only source vs read-write document/library-folder modes) unevidenced on this app | WW-008 register; `M1-REF-020` and `M1-DUR-029` under grant A; programmatic subsets first; Developer ID/clean install → WW-041/052 |
| R4 | GUI keyboard/VoiceOver/visual-settings verification depends on a single coordinator-held GUI lock and temporary OS setting changes (grants A/B/D) | Serialize GUI runs under the lock; record and restore original OS values; static AX checks and model-level tests proceed in parallel |
| R5 | Device-local prior gives no cross-device recovery | Stated limit; Q1 experiment |
| R6 | **Only while the container default is in use:** container loss would lose library aliases/collections/order | Visible "Library stored on this Mac only" status + Move Library command (C2a); library prior checkpoint; show documents remain canonical |
| R7 | Claimed host far exceeds reference (128 GiB vs 16 GB) | Measurements labelled claimed-host only; WW-052 |
| R8 | Metadata-only proof covers app requests, not OS/provider work | Gateway spy + forbidden-API check; limit stated |

## 8. Deferred questions

- **Q1** Portable (cross-device) prior checkpoint placement (embedded vs sidecar related item) — experiment later.
- **Q3** Device-local crash snapshot while autosave is OFF.
- **Q4** Remaining consents (§9): second device, OneDrive, Dropbox and disk-image (real full-volume) tests. (GUI, VoiceOver, visual settings and one iCloud Drive trial folder were granted 2026-10-04.)
- *(Former Q2 — library location — resolved by coordinator decision 2026-10-04; see C2a.)*

## 9. Consent ledger (as known to Lead on 2026-10-04)

| Activity | Status |
| --- | --- |
| Synthetic generated fixtures in temp dirs, unit/integration tests, `xcodebuild`/`swift test` | **Authorized** (kickoff) |
| Ad-hoc local signing ("Sign to Run Locally") | Authorized for builds; no credentials |
| User-provided local disposable episode copy (path withheld) | **Consent relayed by M1 coordinator** — manual M1 import/library/recorder-grouping/primary-backup/relink validation only, read-only, no decode/analysis/transcription, never in automated tests or repo (`M1-USER-001`). Lead has not seen the original user message. |
| **Grant A** — local GUI launch, XCUITest, accessibility audits and computer-use on the ad-hoc-signed app, under a coordinator-held single GUI lock; the user approves any prompts | **Granted by user 2026-10-04** (relayed by coordinator) — `M1-DUR-026`, `M1-REF-020`, `M1-A11Y-001`, native-window `M1-SCALE-001` variant |
| **Grant B** — temporary VoiceOver for the core M1 tasks | **Granted 2026-10-04** — `M1-A11Y-002` |
| **Grant C** — one iCloud Drive folder `WaveWrangler-M1-Synthetic-Trial`, generated synthetic documents only, on this Mac: save, autosave, two-window/two-process conflict, brctl evict/download and recovery; delete the folder afterwards | **Granted 2026-10-04** — `M1-DUR-024`, `M1-SRC-ON-PROV-001` |
| **Grant D** — temporary Increase Contrast, Reduce Motion and larger text, with original values recorded and restored | **Granted 2026-10-04** — `M1-A11Y-003` |
| **Grant E** — synthetic iCloud Drive testing on this Mac and the user's Mac mini (same Apple account), including deliberate multi-device testing; UI stays on the Mac mini | **Granted by the user directly, 2026-10-05** — `M1-DUR-025`, frozen by `m1-freeze-2` ([#116](https://github.com/brandonmartinez/WaveWrangler/pull/116)) before execution. Executed and failed twice (95/100, 99/100). Live qualification was then deferred to [#146](https://github.com/brandonmartinez/WaveWrangler/issues/146) by the user (2026-10-05 23:10); the live tests are gated off by #150 (`270b00b`). The consent itself is unchanged |
| Standing consent — all ongoing and future UI, VoiceOver and related accessibility work on the Mac mini; the disposable episode copy at the same location on the mini under the same consent | **Granted by the user directly, 2026-10-05** |
| OneDrive; Dropbox; disk-image (real full-volume) tests; network disconnection; any provider trial beyond grants C and E | **Not authorized** — `M1-DUR-030`, `M1-SRC-ON-PROV-002/003`, `M1-DUR-013` real-volume variant |
| Recording/sample-folder browsing, model downloads, signing credentials, publishing | **Not authorized** |

## 10. Change log

- 2026-10-04 — Initial record (Lead). Contracts selected; no outcome accepted.
- 2026-10-04 — Review fixes (PR #51): configurable library location (C2a, former Q2 resolved by coordinator), split read-only/read-write bookmark modes, C3-derived boundaries P1–P7 with public injection points and library boundaries L1–L6, unpublished edit-checkpoint record (C2b), disk-image variant not authorized, user grants A–D recorded.
- 2026-10-05 — Consent ledger: grant E (multi-device iCloud, UI on the Mac mini) and standing Mac mini UI consent added; second device no longer unauthorized.
- 2026-10-05 — Status amendments at M1 exit (Lead): C2a "retire" keeps the old copy as a backup and never deletes it; existing-library destination combines by ST-36; L2/L3 queue library edits in a durable journal; Grant Access checks `libraryID`; C4 library merge exception. Evidence and acceptance are recorded in the [M1 exit record](../planning/milestone-exits/m1.md), not here.
- 2026-10-05 — Grant E status: DUR-025 deferred by the user to #146 (23:10); see the M1 exit record §6.
