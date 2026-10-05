# WaveWrangler Squad

> Milestone execution team for a macOS utility with local audio processing and cloud-hosted canonical projects that prepares multitrack podcast recordings for DAW-neutral mixing.

## Coordinator

| Name | Role | Notes |
|------|------|-------|
| Squad | Coordinator | Routes work and enforces handoffs; Lead owns product and technical integration decisions. |

## Members

| Name | Role | Charter | Status |
|------|------|---------|--------|
| Lead | Lead / Product Architect | `.squad/agents/lead/charter.md` | ✅ Active |
| Mac | macOS App Engineer | `.squad/agents/mac/charter.md` | ✅ Active |
| Design | macOS Product Design / Interaction Specialist | `.squad/agents/design/charter.md` | ✅ Active |
| Alignment | Audio Alignment / DSP Specialist | `.squad/agents/alignment/charter.md` | ✅ Active |
| Pipeline | Speech / Editing-Pipeline Specialist | `.squad/agents/pipeline/charter.md` | ✅ Active |
| Scribe | Silent Memory / Decision Log | `.squad/agents/scribe/charter.md` | 📋 Silent |
| Ralph | Backlog / Work Monitor | `.squad/agents/ralph/charter.md` | 🔄 Monitor |
| Rai | Background RAI Reviewer | `.squad/agents/rai/charter.md` | 🛡️ Background |
| Fact Checker | Verification / Devil's Advocate | `.squad/agents/fact-checker/charter.md` | 🔍 Active |

## Project Context

- **Owner:** Brandon Martinez
- **Description:** WaveWrangler prepares multitrack podcast recordings with local audio processing, referenced source media and cloud-hosted canonical project documents in MVP.
- **Initial use case:** A durable show/project library contains multiple episodes. Group and align recorder tracks, correct drift, select speaker-primary tracks, transcribe and human-review filler suggestions, apply safe common-map shortening by default with editable protected alternatives, and export zero-origin per-speaker cleaned stems plus an editable reconstructive cut record for DAW-neutral mixing.
- **Product direction:** The utility may grow into a full podcast editor later, but that expansion is not part of the initial plan.
- **Operating mode:** User-directed 2026-10-04 publication is documents only; GitHub issues/milestones become the operational backlog now. A copied named milestone kickoff authorizes that milestone's engineering, builds/tests, scoped dependency restores, commits/push and independently reviewed PR merges. WW-009/019/030/037 record selected contracts/evidence/risks, not another generic user approval. Dependencies gate outcome acceptance, not safe provisional implementation. M1-M4 deliver internally on this Mac; first audio handoff is full cleaned-track M4. Public artifact/reference-device/broader participant qualification is separate Release WW-041/052, never a deferral of core source/durability/protected-speech/offline/privacy/keyboard/accessibility safety.
- **Consent boundaries:** Recording inspection/processing, exact model bodies/native asset provisioning, provider/cloud/network trials, GUI/OS settings, signing credentials and external publishing remain exact-scope user gates. Source-download ON does not authorize agent sample access. No external service receives recordings; runtime availability stays unknown until observed.
- **Operational authority:** `docs/planning/github-backlog.md`/`.json` index live GitHub milestones/issues; `docs/planning/milestone-runbook.md` and named kickoffs govern execution. `owner:*` labels are informational, never `squad`/`squad:*` auto-dispatch. Parent/Scribe is the single shared-doc writer; concrete writing units use isolated sessions/worktrees/branches/PRs, at most four live writers plus coordinator and one independent reviewer including nested agents.
- **Approved evaluation direction:** Apple silicon only; macOS 26+; English only; 16 GB initial performance reference (not measured minimum); signed/notarized direct download first. Autosave and configurable automatic source downloads ON by default with explicit Save/off and accessible conflict/offline/cancel/retry/recovery states. Common audio formats subject to validation; configurable 48 kHz/24-bit PCM WAV default with feasible source-derived settings.
- **Unknowns to validate:** Native document lifecycle and storage format, provider consistency/save cadence, codecs, exact speech engine/model/assets/rights and measured platform/performance support. No framework, JSON/SQLite/package or model choice is adopted. Portable media copies and DAW-native adapters are deferred.
- **Decision provenance:** Accepted Q01–Q10 direction is in `.squad/decisions.md` and its retained decision-inbox record; detailed user-answer ledger belongs in `docs/planning/research.md`. Historical evidence is not reverified by integration.
- **Project:** WaveWrangler
- **Created:** 2026-10-04T00:32:38.878-04:00

## Catalog Note

Design was added by user authorization on 2026-10-04. This authoritative roster and routing are current; installed/generated capability catalogs may lag. No installer, tooling, or derived governance regeneration was performed.
