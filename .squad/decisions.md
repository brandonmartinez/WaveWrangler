# Squad Decisions

## Active Decisions

### 2026-10-04T00:32:38.878-04:00: Begin in research and planning mode

**By:** Brandon Martinez; recorded by Lead

**What:** The initial team will produce use cases, constraints, architecture options, a risk register, uncertainty-retiring experiments or prototypes, and a staged roadmap. No application implementation begins until Brandon Martinez approves the plan.

**Why:** WaveWrangler crosses macOS application architecture, audio synchronization and drift correction, speech processing, transcript-driven editing, privacy, and DAW interoperability. Research must retire the highest-risk assumptions before implementation choices harden.

### 2026-10-04T00:32:38.878-04:00: Establish domain ownership

**By:** Brandon Martinez; recorded by Lead

**What:** Lead is the sole integration owner and decision authority. Mac owns Apple-platform feasibility and app-level design. Alignment owns synchronization and drift-correction research. Pipeline owns transcript-to-edit semantics. Scribe records, Ralph monitors, Rai advises, and Fact Checker verifies.

**Why:** Clear ownership prevents duplicate research and ensures cross-domain tradeoffs are resolved through one product and architecture authority.

## Governance

- Lead records accepted product and architecture decisions here.
- Specialists submit evidence and proposals through the decision inbox; they do not unilaterally redefine another domain.
- Entries are append-only. Corrections and superseding decisions are recorded as new entries.
- Keep history focused on learnings and decisions focused on authoritative direction.

### 2026-10-04: Accept completed Q01–Q10 product direction for bounded research/design

**By:** Brandon Martinez (@brandonmartinez); accepted and recorded by Squad (Coordinator)

**Provenance:** Completed interview began 2026-10-04T01:28:14.748-04:00. Explicit directions captured in `decisions/inbox/copilot-directive-2026-10-04-q01-q10.md`; retained as accepted provenance. The existing research decision ledger is the detailed interview record, not a separate Q&A document.

**Accepted policy:** A durable show/project library with multiple episodes; referenced media, deferred portable copies; cloud-hosted canonical project documents in MVP; autosave ON by default/configurable/off plus explicit Save; Apple silicon/macOS 26+/English evaluation; signed/notarized direct download first; safe synchronized common-map shortening by default with human acceptance and editable per-cut alternatives that cannot waive speech protection; DAW-neutral zero-origin per-speaker cleaned stems plus an editable reconstructive cut record and explicit asset requirements; configurable 48 kHz/24-bit PCM WAV default and feasible source-derived settings; 16 GB initial performance reference, 8 GB later; approved provisional calibrated quality/accessibility targets; common macOS import formats subject to validation; automatic source download setting ON by default with accessible status/off/cancel/retry/offline safeguards.

**Accepted permission:** Bounded synthetic experiments/disposable research prototypes in the next research phase only. This supersedes any legacy initial-mode wording that would prohibit that approved scope. Production app implementation, user recording access/processing, dependency installation, each exact model download (after source/license/size), native asset provisioning/network consent and provider/network/cloud-writing trials remain separately gated. This decision does not authorize executing research during the document-integration task.

**Not accepted as architecture or fact:** In-memory state/snapshots/save cadence; file/package/JSON/SQLite; AppKit NSDocument + SwiftUI versus SwiftUI document lifecycle; SpeechTranscriber versus local Whisper/exact models; codec guarantees, provider atomicity/universal sync, device minimums or license clearance. Mac/Design, Alignment and Pipeline must retire these unknowns with scoped evidence before Lead recommends choices. Cloud storage is not blanket local-only; scoped permission is not a long-lived lock. Source-download policy never implies consent to access the user's actual samples or install a model.

**Supersession and ownership:** Prior scope recommendations and unapproved-question markers must be reconciled to this policy; prior logs/reviews/source verification remain historical, not approvals of revised artifacts. Lead is the sole planning-document writer; Squad alone updates authoritative team/accepted-decision context. No unrelated charters, histories, catalogs, tooling, Git/settings or issues are changed.

### 2026-10-04: Publish operational backlog and deliver internal MVP milestone by milestone

**By:** Brandon Martinez (@brandonmartinez); user-directed publication/execution handoff, recorded by the publication session.

**Provenance:** Explicit later user decisions relayed by the product-planning coordinator authorize GitHub milestones/issues now and publication in an isolated worktree through commits, push and an independently reviewed PR before merge. Later decisions supersede earlier local-backlog/no-issues/research-only and pre-app public-signing phase wording; they do not rewrite historical evidence or grant input permissions.

**Accepted delivery:** Four internal usable milestones on this Mac: M1 durable organizer (no decode), M2 validated import/alignment, M3 local selected-primary speech/protected human edit review, M4 cleaned zero-origin speaker stems plus editable reconstructive record/assets/restoration. First audio handoff is full cleaned-track M4; no optional uncut M2 handoff. Release separately qualifies signed/notarized direct distribution, actual macOS26/16GB, broad participant/device/accessibility/listening/rights/clean-install claims. Future copies/native adapters remain optional.

**Engineering authorization:** Publication is documents only. A copied named kickoff authorizes that milestone's code/build/test, changed-manifest or missing-dependency restores, isolated branches/worktrees, commits/push, independently reviewed PR merges and relevant issue updates. WW-009/019/030/037 record selected contracts/evidence/risks, not another generic user approval. Dependencies gate accepted outcomes, not safe preparatory coding; do not demand a complete production-like research prototype before creating the app.

**Stage scope:** WW-003/008 are M1; WW-003 closes with complete M1-applicable fixture/provenance/truth/freeze protocol and evidence, leaving later qualification in domain issues. WW-008 closes on feasible lifecycle/support/permission/privacy/rights registers, not a nonexistent signed artifact. WW-041 moves to Release and depends on WW-042 rather than blocking it. New WW-052 depends on WW-042/041/007/008/018/026/029. Preserve the 51 original stable IDs and all historical 196-edge snapshots; current graph is 52 IDs/203 acyclic edges/49 open items, with completed WW-001/002/004 retained history.

**Non-deferrable:** Immutable sources/cloud canonical durability, protected meaningful/other speech, provisioned offline/privacy and essential native keyboard/accessibility remain current-milestone acceptance. Numeric gates and failed research controls remain unchanged. Broad reference/participant/public artifact qualification does not block approved safe internal use, but no unsupported public claim may be made.

**Permission and execution boundaries:** Recordings/model bodies/native provisioning/provider/cloud/network/GUI/OS settings/signing credentials/external publishing still need exact user scope; source-download ON is not agent sample consent. Actual Squad dispatch, one isolated worktree/session/branch/PR per writing unit, maximum four live writers plus coordinator/one independent reviewer counting nested agents, three native builds at `-jobs 4`, and one coordinator/Scribe shared-doc writer. Labels `owner:*` are informational, never auto-dispatch. Continue safe independent work through blockers, correct failures/reviews/conflicts, and stop only at the proven milestone boundary with an exit and next copyable kickoff.

**Reviewed-handoff clarification:** The future M1 kickoff permits minimal ordinary native build/test CI declared as M1 code, including repository workflow files, but not repository/permission settings, auto-Squad dispatch, deployment/upload/release automation or signing credentials. The publication session itself remains documentation-only with no workflow changes.

### 2026-10-05: M1 exit decisions and M2 content consent

**By:** M1 coordinator decisions (2026-10-04/05) and user consents relayed by the coordinator; recorded by Lead in the M1 exit unit. Evidence and acceptance status live in `docs/planning/milestone-exits/m1.md`, not here.

**Library (amends WW-009 C2a/C4):** The canonical library location is configurable: the app container by default, or a user-chosen folder including cloud folders. This overrides the earlier container-only proposal. "Retire" an old library copy means stop reading and writing it and keep it as a backup; WaveWrangler never deletes it. Use That Library and L4 Combine (Keep Everything) follow Design's ST-36 combine rule and never drop entries, recents or collections. In L2 (unreachable) and L3 (needs permission), library edits are queued in a durable device-local journal, replayed through the base check, three-way merged on divergence and routed to L4 when a change can't be carried; the journal clears only after verified publication. Library identity is a logical `libraryID` (library schema 2); Grant Access accepts a folder only when it holds the same library. Show documents keep C4's no-automatic-merge rule.

**Test hooks:** UI-test hooks are Debug-only and absent from Release builds.

**Not granted in M1:** second device; OneDrive, Dropbox and other providers; real full-volume disk-image tests; the Full Keyboard Access toggle; colour filters; network disconnection. The manual Full Keyboard Access run is a user-only post-exit verification, never inferred from automated key events; any failure reopens WW-007 (#8) as P0.

**Issue closure at M1 exit (coordinator, 2026-10-05):** close an issue only when every acceptance criterion is evidenced within granted consent. A criterion blocked solely by ungranted consent keeps its issue OPEN with a "Blocked — needs user" checklist; it is not transferred while the user can't approve a transfer. If any required issue stays open, the M1 milestone stays open. A narrowed WW-049 cloud claim (iCloud Drive observed on this one Mac plus local-process and simulated-provider multi-writer evidence) is PROPOSED for the user's approval, not decided.

**Scope rulings at exit:** Unimplemented M1 UI items (#68–#76, #103) are P2 M2 follow-ups unless the acceptance pass shows a core M1 task can't be completed without one (then P0 M1). REF-019's "primary change marks dependents stale" clause is not evidenced and not claimed (no dependent derived work exists in schema v1); the registry is not revised, and stale-marking is required in M2 by WW-020/WW-022 (Lead).

**Fixture freeze:** the WW-003 protocol was not frozen before execution. `m1-freeze-1` (2026-10-05, PR #62) freezes it retroactively without changing gates, truth or counts; earlier runs are labelled pre-freeze, and holdout claims cite post-freeze runs at the frozen counts only.

**M2 content consent (user-directed, relayed 2026-10-05):** The user-provided disposable local episode copy (path withheld) is approved for M2 import, decode, time-map, group-alignment, manual-correction and channel-consistent asset validation, locally only. It is read-only (temporary copies for any modification). Its path, file names, transcript text and excerpts are never committed or posted. No cloud/provider upload or external service; no transcription or speech analysis (M3). Automated tests keep synthetic fixtures. Model bodies, other recordings, provider/network trials, signing credentials and external publishing remain unauthorized for M2 unless the user grants them.

**Standing GUI consent on the Mac mini (user-directed, 2026-10-05):** all ongoing and future UI, VoiceOver and related accessibility work (app launch, XCUITest/audits, computer-use, temporary VoiceOver and display/accessibility settings with originals recorded and restored) may run on the user's Mac mini, under the single GUI lock with host-labelled results. This does not cover GUI takeover of the user's main working Mac, provider/cloud trials or additional media.

**iCloud and media on the Mac mini (user-directed, 2026-10-05):** synthetic iCloud Drive trials may also run on the Mac mini (the user's same Apple account), with grant-C scope: dedicated trial folder, generated synthetic files only, deleted afterwards. The disposable episode copy is at the same location on the mini, under the same M1/M2 consent. A deliberate two-device conflict trial (main Mac + mini) is not yet confirmed and stays a user decision.

**Process deviations disclosed:** M1 briefly ran 5–6 writer sessions during short review-fix rounds (budget 4) and had windows with two concurrent read-only reviewer agents (budget 1); `gh pr create` was used as a fallback for six PRs when `create_pull_request` was bound to a merged PR; one batched keystroke briefly listed the consented episode folder's parent's metadata in-app (nothing read, imported or committed). The M2 kickoff restates the budgets and rules.
