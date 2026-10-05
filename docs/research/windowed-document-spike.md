# Windowed native document research — closed UI batch

> **Publication notice:** This report describes archived historical evidence and phase permissions, not current execution authority. Public JSON companions are pointer-redacted and **NOT byte-identical archived mirrors**; [original versus published hashes](../planning/publication-provenance.json) are separate. Measurements, pins, artifact hashes, counts and failed controls remain unchanged. Local archive placeholders are not browsable repository links. [Current user-directed milestone policy](../planning/milestone-runbook.md) supersedes old no-issues/research-only phase restrictions without granting input consent.

**UI_BATCH_CLOSED · 2026-10-04 · LOCAL partial evidence · integration owner: Lead.** Requested by Brandon Martinez (@brandonmartinez). This closes the finite synthetic UI batch, **not the whole spike, M1, an accessibility gate or production implementation**.

## Assembled findings — Lead synthesis, not verbatim reviews

- Four retained bounded passes, five **pass-limited**, one partial, one **failed-candidate**, one blocked and two not-executed account for all **14 planned IDs**. Original and corrected observations remain separate below; these are not fourteen successful or statistically independent workflow validations.
- Focused AX set-value plus AXConfirm committed one Rename Show at revision1. Stock native ON autosave followed at **17:29:47Z**, after the **17:29:42Z** rename: approximately **five seconds**, second-resolution evidence with configured delay5. This is **not a ≤2-second pass or guaranteed deadline**. The plan's separate UI08 title was not exercised.
- Requested OFF visibly set checkbox0/`autosavingFileType=nil`, but native scheduling continued: four empty-type encoding failures **WaveWranglerResearch/1004** and a native Not Saved popover. The **8.05966941601946s / 16-sample** unchanged revision3 observation establishes failed persistence, **not safe disablement**. Explicit Cmd-S saved revision4; requested ON was restored.
- Native New, initial Save, valid Open, dismissible malformed/newer refusal, clean Close and clean Quit have bounded evidence. Named Save As/cancellation/second file remain unestablished; Revert lacked specific destructive consent. No unsaved-close cancellation, discard or crash recovery occurred.
- Mac supplied an **author-role technical review**, Design a **read-only four-record evidence review**. Neither reproduced the batch or performed human/user/VoiceOver testing. Their exact returned reviews appear in the appendix.
- Native scheduling/safe publication/versions stayed stock in this windowed harness; representations, validation, edits/undo registrations, scope guards, requested-OFF policy and presentation observer remain subclass responsibilities. **Do not adopt the harness or draft correction into production.**

[Compact results](windowed-document-results.json) · [historical planning research](../planning/research.md#historical-windowed-document-evidence--2026-10-04) · [historical backlog](../planning/backlog.md#historical-windowed-document-integration--2026-10-04) · [README](../../README.md).

Continuation: [synthetic import/time descriptor results](fixture-import-time-results.md) — bounded WW-003 evidence only; no decoding or status change.

## Evidence and provenance

All scratch references below are relative to:
`<research-artifacts>/research/macos-window/`.

| Ref | Read-only source | Meaning |
| --- | --- | --- |
| P | `operator/ui-case-plan.json` | Fourteen planned goals/expectations and original one-launch authorization; not execution evidence. |
| O | `operator/original-build-observations.json` | Parent's original actual observations; interruption/disappearance and then-building correction metadata remain historical. |
| C | `operator/corrected-build-observations.json` | Parent's actual corrected observations, final document/fixture/process checks and supplemental launch accounting. |
| W | `operator/off-window-observation.json` | Passive filesystem-only OFF observation; no UI/save/scheduling intervention. |
| R | `experiment/runtime/events.jsonl` | Original journal: 806 entries, one launch. |
| V | `experiment/corrections/draft-preservation-v3/runtime/events.jsonl` | New corrected telemetry: 2,707 entries across **two launches**, sequences reset. All V sequences cited here refer to the **second corrected launch**. |
| B / B3 / S3 | `experiment/build-ready.json`; `experiment/corrections/draft-preservation-v3/build-ready.json`; `experiment/corrections/draft-preservation-v3/final-static-verification.json` | Historical build/static readiness, not UI results. Their NO LAUNCH/untested fields are not rewritten. |

Lead read P/O/C/W, B/B3/S3 and bounded R/V excerpts plus current README/planning documents. Lead did **not** read working/master documents, other operator/verification files, private native caches/version stores or frozen prior experiments/reports; no direct source inspection or independent file/process verification was performed in integration. Parent's independent parsing and scoped journal reads are attributed as such. No execution or source re-verification is inferred from documentary inspection.

Launch accounting is **one original + two corrected = three**, preserving original permission and subsequent explicit fix/restart and Reopen selections. Original R#805–806 records closure at 16:14:53Z, **not its cause or a native Quit test**. Corrected clean Cmd-Q closed two remaining windows at 17:43:32Z (V#2456–2457); C reports a subsequent **exact corrected-executable probe with no PIDs**. This shutdown/process conclusion is **parent evidence**, not a fresh Lead/reviewer probe.

## Planned-case accounting

`pass` retains the record's bounded classification, never every plan expectation. `not-retested` means no separate corrected claim; original evidence is retained. Original unlisted cases are not-executed, while original UI14 explicitly remains not-tested.

| ID / planned goal | Original O | Corrected C | Closed-batch disposition and unmet expectations |
| --- | --- | --- | --- |
| UI01 launch/AX window | pass | not-retested | Retained bounded pass: window9396, research banner/labelled controls. No full keyboard, visual or VoiceOver coverage. |
| UI02 native New | pass | not-retested | Retained bounded pass: unanchored Cmd-N created window9611; anchored dispatch lacked a candidate. Full menu-surface acceptance unestablished. |
| UI03 field edit/commit | partial | pass-limited | Original draft visibly reset, no rename, revision0/clean. Corrected **focused** set-value + Confirm commits title “Synthetic UI Show A” once at revision1, dirty/unautosaved (V#205–212). Unfocused draft and general focus-preservation acceptance untested; original inferred diagnosis remains inferred. |
| UI04 initial native Save | pass | not-retested | Native sheet saved new A file, revision0/original title; R#17–24 native **saveAs** at 16:08:26Z is the initial untitled Save, **not named UI05/UI06 success**. Parent parsed full envelope. |
| UI05 named Save As/cancel | blocked | blocked | Shortcut acknowledgement `done` produced no established sheet/save event. Cancellation, retained URL/focus and its cause unestablished; no forced enablement. |
| UI06 Save As to B | not-executed | not-executed | No second file, new URL, prior-byte-preservation or cancellation outcome. |
| UI07 document Undo/Redo | not-executed | pass-limited | Initial field-editor Cmd-Z affected text only. Table focus gave document Undo to original title/revision2 at 17:33:00Z (V#628–633), Redo to title A/revision3 at 17:33:07Z (#663–668). No general history or clean-flag persistence guarantee. |
| UI08 native automatic ON save | not-executed | pass-limited | Rename17:29:42Z → stock autosaveInPlace17:29:47Z (V#224–233), scoped full-envelope equality/hash at #236 and parent parsing, revision1/title A. Approximately5s/delay5, not ≤2s; planned “Synthetic UI Autosave Observation” was not a separate edit. |
| UI09 OFF/edit/explicit Save | not-executed | failed-candidate | OFF/nil at V#860; memory revision4 at #939; **four continued native save attempts** fail empty-type encoding (#956–1057), native Not Saved popover. W's sixteen samples stayed disk revision3 over8.0597s. Cmd-S persists revision4 (#1134–1144), ON restored #1162. Accepted OFF policy **fails**, despite explicit-Save recovery. |
| UI10 native Open valid | not-executed | pass-limited | Working-scoped native panel followed by window10521, schema1/revision0/two episodes and full-envelope equality (V#1394–1403). AXOpen transport `no_viable_candidate` coexisted with later actual effects: no blanket transport reliability/causality claim. |
| UI11 newer/malformed refusal | not-executed | pass | Bounded read-refusal pass: subclass schema errors1002/1001 (V#1911–1912/#2069–2070), actual native alerts and OK dismissal per C. Parent reports masters/original working fixtures unchanged. Not migration or all edit/save-path protection. |
| UI12 Close/unsaved cancel | not-executed | partial | Cmd-W closed **clean valid-working window only**, V#2401 at17:43:05Z. Planned unsaved decision/cancellation/recoverability not exercised. |
| UI13 Revert | not-executed | not-executed | No specific destructive Revert/discard consent; restored-content/version/recovery expectations unmet. |
| UI14 clean Quit | not-tested | pass-limited | Original disappearance has unknown cause. Corrected Cmd-Q closes two clean windows, V#2456–2457, and parent exact no-PID check. Not discard, unsaved cancellation, forced termination or crash recovery. |

**Exact denominators:** original14 = 3 pass + 1 partial + 1 blocked + 1 not-tested + 8 not-executed. Corrected14 = 1 pass + 5 pass-limited + 1 partial + 1 failed-candidate + 1 blocked + 2 not-executed + 3 not-retested. Combined retained14 = **4 pass + 5 pass-limited + 1 partial + 1 failed-candidate + 1 blocked + 2 not-executed**. Original/corrected totals overlap the same IDs; never sum them into28 independent tests.

## Native boundary, saved-content and host qualifications

AppKit owns stock scheduling, staging/safe publication/completion, change tokens and native document/panel lifecycle in this harness. The subclass owns immutable JSON representations/schema refusal, edits/undo registration, scope validation/panel customization and the failed OFF candidate. Relevant superclass arguments/tokens are forwarded unchanged. The one-second presentation observer samples state without driving saves; uncoordinated point-in-time reads are **not checkpoints**. Stock version behavior was retained, not validated as recovery. This is separate from earlier native research overrides; its earlier numeric proofs/outcomes remain unchanged.

The corrected source-root/working location remains absolute/stable at `experiment/working`; telemetry moved to `experiment/corrections/draft-preservation-v3/runtime/events.jsonl`. Original/corrected code, build evidence, failure logs and historical prelaunch manifests are preserved, not rebuilt or rewritten. Normal OS-managed **synthetic autosave/draft/version/recent/restoration metadata may occur**; there is no zero-hidden-activity claim, cache browsing or provider trial.

| Parent-observed/generated state (not independent Lead/reviewer hashing) | SHA256 / provenance |
| --- | --- |
| Initial A, revision0 / “Synthetic Research Show” | `0b8478e91b125764fb7c3df81e01c088b6f7a304a5fabb9bcf7583fe4ffcba25` — O parsing, R native save/encode. |
| Automatic ON save, revision1 / “Synthetic UI Show A” | `29e250fffc680508ebf84b9ab12e0405e7b0257d675906df40e9e57d3a6d1e86` — C parent parsing, V#236 sampled full-envelope equality. |
| OFF passive disk, revision3 / “Synthetic UI Show A” | `ae627b57f10a6932a1ab3129837dc38c9479dde4700dc310d0f84c61ecbde635` — W sixteen samples, not scheduling disablement. |
| Final A, revision4 / “Synthetic UI Manual Save Observation” | `d4f93ee0b3459886a9f4ee645c6fa9557e8e36b1c4401338ae357ba32387468c` — C parent final parsing/hash; V#1137 serialization and #1144 scoped equality. File: `experiment/working/ui-operator-show-a.wwresearch`. |
| Valid-working, revision0 / two episodes | `b850354f0b31a86b244103b4d3e192835730076c1323cf2511e82577dbe6ceef` — C, V#1403. Parent reports valid/malformed/newer masters **and original working fixtures unchanged**; no new independent fixture hashes. |

Build evidence: original attempt01 failed/attempt02 succeeded; v3 compiler cycle3 had one invocation/exit0, 33 static checks, executable `fd59f64ae81a1759ae0779415f2ed7d8536f59f8b2eb7e74998347efbf4f31e9` (original `04798b952ab286fe0d28acd3b780b26882f086efb6069f8334c6c041f4b97b8f`). **Swift6.4, language mode6, arm64 target macOS26.0** is compilation evidence, not UI or runtime26 support. Operator/build-reported host **macOS27.0.1 build26A434 / arm64 / 128GiB**, not macOS26 runtime or16GB reference qualification. Historical manifests' “not executed” labels remain build-time facts, superseded only by separate actual UI records.

## LOCAL backlog and acceptance disposition

Add limited evidence only to **WW-005, WW-008, WW-049; all remain PARTIAL**. No status, ID, dependency, owner, priority, type or acceptance-criterion changes. Before/after: **51 stable IDs / 196 edges / acyclic / 51 topological nodes / 23 higher-ID prerequisites; 3 documentary-COMPLETED / 14 PARTIAL / 34 PENDING**. Completed WW-001/002/004 retain their earlier documentary scopes; WW-007/009/010/011/012 and M1 remain pending/unapproved. WW-006 receives no new reference/download evidence.

Graph fingerprint (ordered dependencies, historical convention) remains `c6692502c03ab1f318f412ff67b4cec1a7edbe5c96cad63460d5916d30c10c43`. Inline documentary checks compare ID sets, edges, all statuses, unaffected item blocks and non-evidence fields; only the three named evidence additions change. Local-link/anchor and JSON accounting checks are documentary, **not application tests**. No old numeric reports were opened or amended.

**Unmet local follow-ups, requiring explicit scope/permission decisions, not an executing GUI replay recommendation:**

- **Mac / WW-005/049:** workable ON/configurable/**OFF** plus explicit Save without continued failing autosaves; strict ≤2s checkpoint goal with correctly resolved endpoints, distinct from configurable cadence. Do not weaken either requirement.
- **Mac / WW-005:** named Save As cancellation/B-file/retention/focus, specifically consented Revert/unsaved close/cancel/discard, crash recovery, unknown-newer edit/save protection, concurrent processes/library reconciliation and≥100 actual boundary interruptions remain unestablished.
- **Mac / WW-007/008, Design / WW-029:** unfocused draft/focus behavior, full native keyboard/menus, VoiceOver/human tasks, visual/contrast/200% text/reduced-motion, macOS26 runtime/16GB qualification and distribution remain open. Labelled AX controls are not these approvals.
- **Mac / WW-006/049:** scoped source/download/regrant/provider/offline/two-machine/cloud consistency remain separate, unexecuted and permission-gated. Cloud canonical MVP is not silently deferred.

The authoritative archived scratch `results.json` and pre-redaction repository `windowed-document-results.json` were byte-identical mirrors. The current public file is a **sanitized-provenance companion, not byte-identical after pointer redaction**; [original and published hashes](../planning/publication-provenance.json) are separate. The historical integration performed documentary reads/writes/checks only: **no launch, rebuild, fourth correction, GUI, process probe, fixture/media access, installs, network/provider work, issue creation, Git mutation or Squad-state write**. Reviews permit integration with failures/unknowns intact, not production adoption or broader completion.

## Appendix — actual returned reviews, unedited

BEGIN MAC REVIEW VERBATIM
Mac — author-role technical review, not independent reproduction.

Read scope: Only the four authorized operator JSON files; original and v3 runtime/events.jsonl; v3 Sources/ResearchDocument.swift, ResearchModel.swift, ResearchWindow.swift, ResearchMain.swift; v3 build-ready.json and final-static-verification.json. No other evidence files or working documents read. No writes, compilation, launches, tests, process probes or Git operations.

Citation shorthand: O=original-build-observations.json; C=corrected-build-observations.json; R=original runtime journal; V=v3 runtime journal. V sequence numbers below belong to the second corrected launch; sequences reset between launches. Times are UTC.

1. Native/subclass boundary is supportable, not “entirely native.” AppKit supplies scheduling, save/staging/completion, change tokens and native document/panel lifecycle. The subclass supplies JSON validation/serialization, edits, undo registrations, scope guards, panel customization and the requested-OFF candidate. ResearchDocument forwards relevant arguments/tokens to super; ResearchWindow’s one-second observer samples state without driving saves. Those samples are uncoordinated, not checkpoints.

2. Preserve original outcomes. O supports bounded UI01/UI02/UI04 passes, UI03 partial without committed rename, and UI05 blocked. R #17–24, 16:08:26, records the initial untitled Save as native saveAs at revision0—not a successful named-document UI05/UI06 operation. R #805–806 records window closure at 16:14:53 but establishes no Quit cause; original UI14 remains not-tested.

3. Corrected UI03/UI07 are limited passes. C records focused AX set_value plus AXConfirm; V #205–212, 17:29:42, confirms one Rename Show registration, revision1 and native dirty/unautosaved state. Unfocused AX draft behavior remains untested. C’s initial field-editor Cmd-Z changed text only; document undo/redo is corroborated separately at #628–633, 17:33:00, revision2, and #663–668, 17:33:07, revision3.

4. UI08 demonstrates native ON saving, but NOT the strict <=2-second requirement. V #224–233 records autosaveInPlace at 17:29:47 after the 17:29:42 commit; #236 confirms revision1/full-envelope equality with hash 29e250ff…. Approximately five seconds, with second-resolution timestamps and configured delay5, is neither a <=2-second pass nor a guaranteed completion deadline.

5. UI09 FAILED as an OFF policy. V #860 records requested OFF/nil; revision4 commits at #939. Four subsequent native saves attempt empty-type encoding and fail with WaveWranglerResearch/1004 (#956–1057). C records the native error popover. off-window-observation.json reports an 8.0597-second observer duration and unchanged revision3 across sixteen samples—not disabled scheduling. Explicit Save succeeds at #1134–1141, 17:36:30; ON returns at #1162.

6. UI10 is pass-limited; UI11 passes the bounded refusal observations. V #1394–1403, 17:38:32–33, corroborates valid-working opening and matching disk state; C identifies window10521. AXOpen’s no_viable_candidate prevents blanket transport-reliability or causal claims. Newer/malformed failures appear at #1911–1912 and #2069–2070. Validation is subclass logic; native alerts/OK dismissals are operator observations.

7. Keep unresolved cases intact: UI05 blocked; UI06 not-executed; UI13 not-executed without specific destructive consent. UI12 covers only clean Close (#2401, 17:43:05). UI14 covers clean Quit of two remaining windows (#2456–2457, 17:43:32). No unsaved-close, cancellation, discard or crash recovery was tested.

8. Final revision4/title “Synthetic UI Manual Save Observation” is reported by C and corroborated by serialization plus sampled full-envelope equality (#1137/#1144):
d4f93ee0b3459886a9f4ee645c6fa9557e8e36b1c4401338ae357ba32387468c
I did not independently hash the file. Parent fixture-preservation and final no-PID checks remain attributed parent evidence.

Recommendation: Integration is supportable WITH these failures/unknowns intact. Preserve historical prelaunch metadata, count one original plus two corrected launches, and retain host macOS27.0.1/128GiB—not runtime26/16GB support. Do not adopt the draft correction into production or declare whole-spike/M1 completion; local backlog remains partial.
END MAC REVIEW VERBATIM

BEGIN DESIGN REVIEW VERBATIM
Design evidence review of the four authorized operator records—not reproduction, human or VoiceOver testing. Verdict: LOCAL partial evidence only.

1. UI01/02/04—original pass: labelled AX controls, native New/Save observed; full keyboard/accessibility coverage unestablished.
2. UI03—original partial (draft reset/no commit) → corrected limited pass (focused Confirm committed revision1 once); unfocused behavior untested.
3. UI07—limited pass: field-editor Undo affected text only; table focus enabled document Undo/Redo revisions2/3.
4. UI08—limited pass: second-resolution evidence shows ~5s with configured5s; ≤2s requirement remains unresolved.
5. UI09—failed candidate: requested OFF still triggered empty-type autosave errors1004/NotSaved. The 8.06s unchanged-file sample proves neither disablement nor acceptable UX. Explicit Save persisted revision4; ON restored.
6. UI10/11—limited pass/pass: actual Open window and dismissible refusal alerts observed. Transport no_viable_candidate did not mean no effect; reliability/causality remains unestablished.
7. UI05/06—blocked/not executed: no Save As sheet, second file or cancellation outcome. UI13—not executed; destructive consent absent.
8. UI12/14—partial/limited pass: clean Close/Quit only; original disappearance was not proven Quit. Clean flags alone never establish saved content.

Lead: preserve these distinctions in the LOCAL partial backlog. Mac: own unresolved interaction/error requirements; no research-fix adoption or production-completion claim.
END DESIGN REVIEW VERBATIM

## OFF scheduling-policy follow-up — 2026-10-04

Brandon's feedback, “that seems like it should be an easy fix to turn off auto saves…”, motivates a **focused prototype scheduling-policy correction**, not a conclusion that OFF is impossible or a change to accepted ON/configurable/OFF or cloud choices. This is a future recommendation only. **UI_BATCH_CLOSED**, all 14 outcomes, UI09's failed candidate/four errors and ~5s ON observation that does not meet ≤2s remain unchanged; historical provenance, numeric proofs and verbatim reviews are not amended.

- Keep a **valid serialization/document filetype for native explicit Save**; do not use `autosavingFileType=nil` or an empty type as disablement.
- Use the **actual enabled flag at public automatic scheduling and queued/autosave boundaries**, preserving native dirty/unsaved state. Identify and verify exact legal hooks and native protocol-compliant handling before presuming coverage; those hooks remain **unverified** here.
- A bounded next candidate must cover already queued ON work when toggled OFF; OFF edits remaining unsaved/preserved with no attempted automatic publication/error loop; native explicit Save with a valid type; ON re-enable with pending edits; and native close/quit decisions so skipped autosave cannot silently discard work.
- Account honestly for skipped/non-save work. No fabricated success-shaped saved callbacks, clearing dirty state or claiming checkpoints for skipped work, private/unsafe hooks, deadlocked native callbacks or silent work loss. Native protocol compliance must be verified, not guessed.

Recommend a **small Mac-owned next candidate under existing WW-005/049 only**; existing Design consultation concerns native unsaved close/quit UX only if later authorized. This adds no acceptance criterion, scope, owner or status change and does not weaken OFF, cloud canonical MVP or strict ≤2s requirements. **Execution is NOT authorized**: no fourth correction cycle, automatic trial/launch, production adoption or destructive action. Destructive decisions still require precise user consent. The closed failed evidence remains available to motivate a verified fix, not another execution in this task.

## Autosave-policy-v1 — separate partial results, 2026-10-04

**New focused candidate evidence, not a rewrite of CLOSED v3/UI09 or authorization for another trial.** Brandon's later “Approve the focused fix and tests (Recommended)” selection authorized the single candidate GUI opening; it succeeded with a real event loop and initial native Save. Lead integrates records only.

Parent evidence, relative to the source root above: `autosave-policy-operator/observations.json`, `plan.json`, `as01-observation.json`, `as01-trial3-observation.json`, `as02-observation.json`, `as04-observation.json`. Only these six operator files were read; no adjacent verification, logs, screenshots, helpers or generated documents.
Mac evidence: `experiment/corrections/autosave-policy-v1/build/async-console-supplement-v1/` — `HANDOFF.md`, `results.json`, `TERMINATION-INSPECTION.md`, retained public SDK/terminate references, run records/stdout/stderr/output provenance and fingerprint manifest. These are documentary sources, not Lead reproduction.
The plan's “not yet performed” and Mac's “inline only / wait for observation file” fields are historical. Parent records now supply actual GUI evidence; their spaced titles below supersede Mac's compressed inline labels. Earlier mirror/check statements concern the closed-batch snapshot; this additive repository record is not a new scratch mirror.

| Case | Actual bounded disposition | Evidence and remaining gap |
| --- | --- | --- |
| AS01 | **Unestablished; three invalid setups, neither pass nor fail** | Every ON edit published before OFF. Trial2 commit/save/OFF: 19:05:21/26/27Z; trial3: 19:07:18/23Z, OFF#627 after completion. Stable post-OFF bytes do not establish queued dirty-race cancellation. No fourth app trial authorized. |
| AS02 | pass-limited | OFF memory revision4 stayed dirty/unautosaved; blocked scheduling#779, no type1004/error loop. Passive observation11.0675s retained full disk revision3/hash `aedb9420…`; finite interval, not all interleavings. |
| AS03 | pass-limited | Genuine OFF Cmd-S used native staging/completion#914–921 and independently parsed full revision4 content; native dirty state cleared through successful Save. |
| AS04 | pass-limited | Pending OFF episode revision5; ON#1541–1542 at19:14:41Z → actual autosaveInPlace#1555–1564 at19:14:46Z and independently matching disk. Configured5s, not ≤2s qualification. |
| AS05 | **PARTIAL** | OFF revision6 Close exposed Save/Cancel; Cancel#2010/2036 retained window, dirty model6 and disk5. Dirty Cmd-Q exposed **no sheet**; implicit=false autosave cancelled3072/#2055–2057, work stayed open. Close→Save#2325–2334 later persisted revision6 before closure; full dirty-Quit UX remains incomplete. |

Parent independently reported saved envelopes/hashes; Lead did not read/hash those files:
- AS03 revision4 / show “Synthetic AS02 OFF Edits”: `d0e51129f774bb2f9afa1e84470d3ec318146bda8094eb2a871208782c3bd1ca`.
- AS04 revision5 / episode “Synthetic AS04 Pending Episode”: `80fcb3e281b96d50aa488ed93a6596dad3a7b19ff3e16964d2a50d1d853b718f`.
- Final named `working/autosave-policy-operator-a.wwresearch`, revision6 / same show / episode “Synthetic AS05 Close Protection”: `b7a147e8f342cf8551a575607ab4b4c8072aab80bc8a33a52d7e32347f8f0cdb`. No loss/deletion/discard reported in this bounded sequence.

After saved Close, a new clean Untitled window10760 appeared; **cause UNKNOWN**. Clean Cmd-Q reached hook#2341–2343; parent's exact executable probe returned **zero PIDs**. App stopped; this does not validate dirty Quit.

**Separate asynchronous console supplement:** one strict Swift6 compile and one new run, both exit0; 19 flushed PASS lines, six actual callbacks (five policy cancellations + one native SaveAs), eight total public-entry/writeSafely cancellations3072. Dirty flags/full model survived cancellation; successful native SaveAs alone cleared flags and stayed OFF. Independent full-envelope, exact-byte and Python disk equality passed; saved fixture SHA256 `b38241437437759efa15bc9486ee65f56f4f9c50f738b823bb1b814b64e5f504`. ON proves scheduling forwarding only, not native publication or a queued timer race.

The original frozen immediate `saveCalls == 1 && saveError == nil` assertion **still failed SIGTRAP/-5 with empty stdout**; no old PASS total is inferred. Retained public NSDocument.h:394–400 permits completion after return even without concurrent writing; the separate awaited result retires that synchronous test assumption, not its historical failure. Mac reports225 named byte/hash/mode comparisons unchanged, app source/executable frozen, no app rebuild.
Native `writeSafely`/publication remained stock. Supplement telemetry recorded normal native NSDocument temporary staging outside the candidate; that path was not read/hashed/enumerated/deleted, and present bytes/existence are unknown. No “all outputs inside” claim. Mac's post-run scope stop followed the completed exit0/pass assertions, not failed assertions.

**Read-only dirty-Quit diagnosis / recommendation only:** retained Apple documentation places document-controller saving **before** `applicationShouldTerminate`. Mac's frozen-code inspection reports direct `terminate:` at ResearchMain:92, but `closeAllDocuments` inside the later delegate:33–40. This public-hook placement gap explains the observed earlier OFF cancellation; the exact internal call stack is unobserved. Small menu/Command-Q candidate: public `closeAllDocuments` first, actual false keeps work open, actual true starts ordinary `terminate`. An earlier callback must not prematurely call `replyToApplicationShouldTerminate` or strand `terminationPending`. No implementation/replay or Dock/system-exit guarantee is authorized here.

**Disposition unchanged:** three limited cases, AS01 unestablished, AS05 partial—not all five passed. WW-005/WW-049 remain PARTIAL;51 IDs/196 edges/3 documentary-completed/14 partial/34 pending unchanged. Strict ≤2s, macOS26 runtime/16GB, whole-spike/M1, cloud/provider and production/framework adoption remain unestablished. This integration changes only the two existing reports; no app/source/build/console/GUI/Git/Squad-state action.
