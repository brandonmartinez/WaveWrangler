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

## Milestone orchestration (M2 onward)

Adopted from the [M1 retrospectives](../docs/planning/retrospectives/m1.md) and the user's 2026-10-05/06 decisions (`decisions.md`). The named milestone kickoff remains authoritative where it is more specific.

| Topic | Rule |
|---|---|
| Unit of work | One **fresh** session per PR unit (worktree, branch, PR), ending at merge. Long-lived lanes don't pick up model or process changes, so don't keep them. `create_pull_request` from that session (never `gh pr create`). |
| Model and effort | Chosen per unit. High-capability: durability, persistence, recovery, source immutability, concurrency, decode/time-map, clock/alignment acceptance, render-path correctness, and the reviewer of those PRs. Mid-tier (medium effort): routine UI/layout, test harness, docs, exit write-ups. Fast: running tests, collecting xcresult evidence, log/benchmark parsing, triage. Never lower review rigor for safety-critical changes. |
| Issue keywords | Never write close/closes/fix/fixes/resolve(s) next to an issue number in a PR body or commit unless that PR is meant to close it. GitHub parses even negated phrasing ("does not close #45" closed #45). Use "Refs #N". Before merging, check `closingIssuesReferences`. |
| Stacked PRs | A session created with `base_branch` defaults its PR base to that branch. Pass `base_branch: "main"` to create_pull_request unless a stacked review base is intended, and check `baseRefName` before every merge; retarget a stacked PR to main once its parent merges. (#208 merged into its stacked base instead of main.) |
| Writer children | Writer sessions never create other writer sessions; delivery problems go to the coordinator as needs_input. |
| Model family (user-directed 2026-10-06 11:47) | Prefer GPT models for every NEW child session and task agent (better spend rates): high-capability = gpt-6-sol or gpt-5.6-sol at high/xhigh effort; mid-tier = gpt-5.6-terra or gpt-6-luna at medium; fast = gpt-5.4-mini or gpt-5-mini. Use a Claude model only with a recorded reason (e.g. a GPT model failed the same unit twice), logged in the PR or decisions. Don't interrupt running sessions to switch. The independent reviewer is a different model or session from the author. |
| Budget | At most 4 live writer sessions + coordinator + 1 independent reviewer, counting nested agents, read-only task agents and review-fix rounds. Writer children never spawn writers. At most 3 native builds on a host, `-jobs 4` each. |
| Review | One independent reviewer per PR, reviewing diffs, CI and the author's attached evidence. **Reviewers never run UI tests or take the GUI lock.** |
| GUI runs | Build on the dev Mac, run on the Mac mini under the self-serve per-host lease ([skill](skills/gui-lock-mac-mini/SKILL.md)). **One run per acquire; status before polling lanes.** The helper releases automatically after the wrapped run. UI testing runs on the **Mac mini only** by default. The user's Mac is a GUI host only inside an explicitly user-granted away window, with its own lock, never with computer-use or VoiceOver, and the grant ends when the user says so. |
| GUI timebox | 3 failed GUI rounds on one PR → Lead (design decision or follow-up issue). Only a **recorded** Lead decision (on the PR and in `decisions.md`) restarts the count; rounds that never ran or were environment-invalid don't count. |
| Regression runner | A named lane, **Regression runner**, started fresh (fast model) for each capped full UI run: build once, shard by test class across GUI hosts, full `scripts/test.sh` on the same SHA, record SHA/hosts/shard map/counts/xcresults. Any failure is triaged and filed immediately; merges in that area freeze until understood. |
| Session hygiene (user-directed 2026-10-07 10:01/12:50) | **Auto-cleanup:** on each idle notification, and in a sweep at least every ~2 h and before each handoff, archive children whose unit is finished. Verify first: PR merged or closed (or the lane was superseded by a later reviser), no open PR, no active Agent merge or session automation, a clean worktree with nothing unpushed, and notes copied to the coordinator's `files/`. Never archive a lane with open or in-flight work. Only the creating coordinator can archive its children. **Crash recovery:** after any app crash, audit every lane, resume or re-run interrupted work, and record interrupted holdouts as interrupted, never as passes. |
| Merge gate: local CI (user-directed 2026-10-08 11:12) | GitHub Actions CI runs only on manual dispatch until after the MVP (re-enable: #252). **Local is the only CI gate.** Before merge, every PR records ONE full `scripts/test.sh` run on the **exact PR head SHA**, with a fresh build (nothing reused), in its body or a comment: SHA, host, 1-minute load at start, and pass counts. Mini GUI classes are added when UI or UI tests changed. While iterating, lanes run the fast suites plus the heavy suites for the code they changed; the full run happens once, before merge. Reviewers check that the recorded run matches the head SHA. PRs that change only docs, Squad config or workflow files (no Swift, Xcode project, `scripts/`, or test code) need no `scripts/test.sh` run; the reviewer verifies the file list. Retained risk: macOS 26 / Xcode 26 coverage is lost until #252 (local hosts run macOS 27 / Xcode 27). Exit gates and holdouts still run the full heavy set locally. |
| Notifications | `notify_on_idle: "once"` per child. Children message the coordinator only for handoff, needs_input or error. No "Waiting…" turns. |
| Issue closure | Close each required issue as soon as its acceptance proof merges, with a closure-proof comment (Lead; [skill](skills/milestone-exit-record/SKILL.md)). |
| Essential accessibility | Every UI PR checks its changed surfaces (keyboard path, AX audits without `.contrast` except on blocked/recovery surfaces, legible blocked/recovery states, no colour-only or drag-only state). A failure blocks the PR. Broad checks are M5 / WW-053. |
| Compute budget (user-directed 2026-10-06 09:27; raises 10-06 16:35 and 10-07 11:37) | The dev Mac is the user's working machine. **Daytime default: 1-minute load ≤ ~24, ≤4 cores per test process, ~3 heavy jobs.** Only the user raises it (e.g. load ≤ ~36–40, ~6 cores per test process), and only for the window stated. No unbounded load generators: anything like `yes` needs a trap and a timeout. Wrap long tests in `timeout --kill-after=…` and check for orphaned `swiftpm-testing-helper` processes afterwards (a plain `timeout` left 300% CPU orphans for hours on 10-07). The full local `scripts/test.sh` estimator pass bursts above the per-process cap, so run it only when load is low; rely on CI for the full package pass otherwise. In the daytime default, `swift test --num-workers` is ≤4 (`--no-parallel` for sweeps) and calibration/sweep/holdout code caps its own concurrency at ≤4 (env/config default; never `activeProcessorCount`), for about 4 cores per test process. During an explicit user-granted raise, workers and internal concurrency may rise only to the granted value (for example, ≤6 at load ≤ ~36); both return to the daytime default when that window ends. Heavy calibration/sweep/holdout jobs run one at a time; check `uptime` first and wait while the 1-minute load is above ~24. Total compiler and test work stays at ~3 concurrent `-jobs 4` jobs on the host, counting every coordinator's lanes. Heavy non-GUI work may use the Mac mini when it has spare capacity (at most one non-GUI lane there, never during a GUI gate run if it would perturb timing). |
| Evidence budget | One short section per gate; no screenshots or crops unless a finding cites them. |
| Gates and waivers | Performance and contrast gates are hard only at milestone exit, judged against the pinned baseline (`docs/m2/evidence/m2-gui-baseline.md`). An accepted-with-issue waiver of a gate (e.g. #220) needs a **user decision**, recorded in a reviewed baseline revision. Narrow audit-artefact handlers need pixel or AX proof and a dated, reviewed revision. Provider/network latency is a measurement, never pass/fail. Transfers of an applicable gate to a later milestone need a user decision and a receiving issue (e.g. WW-018 listening → #232). |
| User asks | One consolidated preflight ask ([skill](skills/kickoff-preflight/SKILL.md)) and one consolidated ask before each away window. |
