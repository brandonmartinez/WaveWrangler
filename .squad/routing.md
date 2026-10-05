# Work Routing

How to decide who handles what.

## Routing Table

| Work Type | Route To | Examples |
|-----------|----------|----------|
| Product scope, roadmap, architecture synthesis, acceptance criteria, tradeoffs | Lead | Research agenda, staged roadmap, build/buy/defer decisions, cross-domain interfaces |
| macOS feasibility and application architecture | Mac | Document model, waveform/review UX, playback, persistence, sandboxing, import/export |
| Native macOS product design, interaction coherence, HIG and accessibility | Design | Project/episode sidebar and navigation, import/group correction, file-status recovery, keyboard/menus/undo, timeline review and manual sync correction |
| Recorder grouping, synchronization, drift correction, DSP quality | Alignment | Offset estimation, drift models, resampling, channel integrity, measurable validation |
| Transcript-driven editing and speech pipeline | Pipeline | Speaker-primary selection, transcription, word timing, filler suggestions, cut semantics, editable-track export |
| Decisions, session history, cross-agent context | Scribe | Merge decision inbox, append logs, propagate accepted context |
| Questions, dependencies, risks, next actions | Ralph | Maintain planning backlog and surface stalled or unowned research |
| Privacy, consent, harmful automation, audio/transcript handling | Rai | Background RAI review of workflows, storage, and model-assisted edits |
| Technical claims, references, assumptions, pre-mortems | Fact Checker | Verify APIs and formats, challenge architecture claims, test load-bearing assumptions |

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| `owner:{role}` | Informational accountable role; no automatic pickup or GitHub assignee | Named roster role |
| `type:*`, `priority:*`, `gate:*` | Scope, ordering and milestone/release/future classification | Lead / coordinator |
| `status:partial` | Narrow evidence exists, applicable acceptance incomplete | Accountable role |

### How Issue Assignment Works

1. Live GitHub milestones/issues are operational authority; local research documents explain evidence.
2. The user starts one named milestone with its copyable kickoff. The actual Squad coordinator dispatches bounded specialist work in isolated worktrees.
3. `owner:*` labels inform accountability only. Do not add `squad`/`squad:*`, auto-start worker sessions, or assign fictional specialist roles as GitHub users.
4. Dependencies gate accepted outcomes, not safe preparatory coding behind provisional interfaces. A blocker affects only genuinely dependent work.

## Ownership and Handoffs

1. **Lead is the sole integration owner and decision authority.** Specialists provide evidence and options; Lead synthesizes and accepts or rejects proposals.
2. **Mac owns Apple-platform feasibility and app-level design.** Mac consults Alignment for audio transformations and Pipeline for edit semantics, without redefining those domains.
3. **Alignment owns synchronization and drift-correction research.** Outputs are testable algorithm options, quality metrics, DSP constraints, and interface requirements—not app UI or transcript behavior.
4. **Pipeline owns transcript-to-edit semantics.** Outputs are timing and edit representations plus model evaluations—not DSP correction or general macOS architecture.
5. **Scribe records, Ralph monitors, Rai advises, and Fact Checker verifies.** None competes with Lead ownership.
6. Cross-domain conflicts route to Lead with explicit options, evidence, risks, and a recommended resolution.
7. A pasted named milestone kickoff grants that milestone's engineering scope. Lead records applicable contracts, evidence, risks and permissions; do not request a second generic approval. True recording/model/provider/native/GUI/destructive consent remains separate.
8. **Design owns product interaction quality, native macOS HIG fit, and accessibility.** Design specifies and reviews coherent cross-workflow navigation and timeline interactions; Mac retains platform engineering, document/file-reference implementation, playback, persistence, and lifecycle ownership. Design does not redefine Alignment's transforms or Pipeline's edit semantics. Lead reconciles disagreements.

## Rules

1. **Milestone-scoped execution** — use the [runbook](../docs/planning/milestone-runbook.md), live issues and actual specialists; deliver internally M1-M4, public Release separately.
2. **Single shared-doc writer** — coordinator/Scribe integrates proposed decision/document updates; no overlapping checkout edits or background Scribe writer racing the parent.
3. **Quick facts → coordinator answers directly.** Don't spawn an agent for "what port does the server run on?"
4. **When two agents could handle it**, pick the one whose domain is the primary concern.
5. **Bounded parallelism** — at most four live writer sessions plus coordinator and one reviewer, counting nested agents; fewer when no independent work. One worktree/session/branch/PR per writing unit, fresh main unless explicitly dependent.
6. **Anticipate downstream questions.** Pair architecture options with validation criteria, risks, and uncertainty-retiring experiments.
7. **No auto-pickup** — issue labels are informational. Work starts only within the named user-authorized milestone; stop at its exit and produce the next prompt, never auto-start it.
