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
