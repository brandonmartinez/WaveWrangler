# Milestone execution runbook

## Current authority and user decision

**User-directed delivery policy, 2026-10-04:** publish the planning source of truth through an independently reviewed PR and create the GitHub backlog now. Deliver usable **M1-M4 internally on this Mac first**, one milestone per orchestrated session. The first audio handoff is the **full cleaned-track M4 MVP**; there is no optional uncut M2 delivery. Qualify public distribution separately in **Release**. These decisions supersede historical research-only, local-backlog/no-issues and pre-app signed-artifact gates, not source, durability, protected-speech, offline/privacy or essential keyboard/accessibility safety.

This publication session authorizes **documentation only**, not application implementation. A user pasting a named milestone kickoff authorizes that milestone's engineering as specified in the prompt. WW-009/019/030/037 record contracts, evidence, risks and scope; they are **not a second generic user-permission request**. Optional adapters retain separate Future authorization.

**Live GitHub milestones and issues are the operational backlog.** Use [the live index](github-backlog.md) and [machine-readable mapping](github-backlog.json). WW IDs remain stable; issue numbers do not replace them. Research reports and [historical backlog](backlog.md) explain evidence, frozen thresholds and failure dispositions, not current operational status. Informational `owner:*`, `type:*`, `priority:*`, `gate:*` and appropriate `status:partial` labels do not dispatch workers. Do not use `squad`/`squad:*` labels or assign fictional specialist identities as GitHub users.

The public research JSON files are **sanitized-provenance companions, NOT byte-identical mirrors of local archives after pointer redaction**. [Publication provenance](publication-provenance.json) records original archive hashes separately from published hashes. Archived-original hashes, measurements, pins, counts and failures are retained; publication does not rerun or qualify them.

**User-directed 2026-10-06 01:20:** add **M5 — Accessible MVP qualification** after M4 and before Release, with new stable ID **WW-053** ([#167](https://github.com/brandonmartinez/WaveWrangler/issues/167)). Broad accessibility portions of WW-007/029 transfer to WW-053; essential accessibility stays an invariant in every milestone ([below](#essential-accessibility-invariant-and-exit-checkpoint)).

## Seven milestones

| Milestone | Demonstrable increment | Required stable IDs |
| --- | --- | --- |
| [M1 - Durable organizer](https://github.com/brandonmartinez/WaveWrangler/milestone/1) | Durable library/sidebar, shows/episodes/metadata/collections, groups/speakers/primaries/backups, immutable references/relink, native Save/autosave/recovery and cloud canonical safeguards. **No decode/analysis required.** | WW-003, WW-005-013, WW-049; WW-001/002/004 are completed documentary history. |
| [M2 - Recording alignment](https://github.com/brandonmartinez/WaveWrangler/milestone/2) | Validated imports/decoded-frame time maps, group clocks/alignment, explicit uncertainty and manual correction, channel-consistent assets. **Not an audio-handoff shortcut.** | WW-014-024, WW-050. |
| [M3 - Speech and edit review](https://github.com/brandonmartinez/WaveWrangler/milestone/3) | Local selected-primary transcription, contextual filler proposals, human-accepted safe common-map shortening or editable protected lift, native review, undo and multi-speaker preview. | WW-025-034, WW-043-046. |
| [M4 - Cleaned-track MVP](https://github.com/brandonmartinez/WaveWrangler/milestone/4) | Zero-origin cleaned speaker stems plus editable reconstructive record/source recipe/assets and demonstrated restoration/regeneration. **First audio handoff; full internal M1-M4 MVP.** | WW-035-038, WW-040, WW-042. |
| [M5 - Accessible MVP qualification](https://github.com/brandonmartinez/WaveWrangler/milestone/7) | Broad accessibility across all MVP windows once UI is stable: 200% text, system Increase Contrast, light/dark, Reduce Motion, VoiceOver listening, FKA, saturation and the zero-unwaived contrast baseline. Entry: M4 accepted, layouts/theme final, waiver baseline pinned at the M4 exit SHA. | WW-053. |
| [Release - Public distribution qualification](https://github.com/brandonmartinez/WaveWrangler/milestone/5) | Signed/notarized direct route, actual macOS26/16GB reference, broader device/participant/listening, rights, clean-install and supported-claim qualification. Broad accessibility is qualified in M5 (WW-053). | WW-041, WW-052. |
| [Future - Optional extensions](https://github.com/brandonmartinez/WaveWrangler/milestone/6) | Separately scoped portable copies and optional native DAW adapters. | WW-039, WW-047/048/051. |

Historical snapshots retain **51 IDs / 196 acyclic edges / 3 documentary-completed / 14 partial / 34 pending**. The approved current graph has **53 stable IDs / 207 acyclic edges**, with **50 open issues**, 3 completed historical items, 14 partial and 36 pending (the 2026-10-04 graph of 52 / 203 / 49 open is the previous snapshot). WW-041 moves to Release, no longer blocks WW-042, and instead depends on WW-042. WW-053 depends on WW-042/007/029. WW-052 depends on WW-042/041/007/008/018/026/029/053. Do not rewrite old snapshots as if they measured this later graph.

### Stage-scoped acceptance, not gate weakening

- **WW-003/M1:** complete fixture permissions/truth/provenance, calibration/holdout freeze and supported-claim protocol, with all applicable M1 organizer/durability/reference evidence. Later M2-M4 domain qualification remains in those domain issues; whole-product empirical coverage must not keep this foundation issue permanently open.
- **WW-008/M1:** establish feasible native lifecycle/support/permission/privacy/rights registers and an honest internal-use envelope. Signed/notarized/clean-installed public artifact proof belongs to WW-041/052 after the app exists.
- **WW-007/029:** essential native keyboard/VoiceOver, core workflow usability, responsiveness and safety remain in their current internal milestone. Broad accessibility transfers to WW-053 (M5): from WW-007, C03–C07, the C02 VoiceOver listen and FKA; from WW-029, contrast, Reduce Motion and 200% text. Only reference-device/participant qualification transfers to WW-052, which depends on WW-053. Documentary/pure-state scenarios are not native accessible or human tests.
- **WW-018/026:** qualify the selected internal renderer/speech path and exact asset rights/permissions on the claimed host. Public support/resource/device breadth is WW-052; offline loading, protected speech, timing and source immutability cannot transfer.

Dependencies gate **declaring an outcome accepted**, not safe preparatory coding behind isolated/provisional interfaces. Do not demand a production-like research prototype or complete M1 UI qualification before creating the application. Implement bounded contracts and tests, iterate with real results, and accept only when the applicable gates pass. A blocked dependency restricts only work that actually relies on it; continue independent safe tasks.

### Essential accessibility invariant and exit checkpoint

Essential accessibility is an invariant in **every** milestone, M1 included. Each UI PR checks only the surfaces it changes:

- keyboard-only path with visible focus and Return/Esc;
- AX role, label and value (audit types `elementDetection`, `sufficientElementDescription`, `hitRegion`, `action`; `.contrast` only on blocked/recovery surfaces);
- every blocked, error and recovery state reachable, labelled and legible;
- no colour-only state and no drag-only interaction.

Each milestone exit includes one checkpoint of at most 30 minutes: in-app 200% text plus light and dark appearance on that milestone's windows. System Increase Contrast is not part of this checkpoint (it is WW-053). Only a finding that makes a core task impossible blocks the exit; every other finding becomes a WW-053 follow-up. Severity follows [accessibility acceptance §6](../m1/design/accessibility-acceptance.md#6-exit-criteria-for-the-design-accessibility-gate-proposal-for-lead).

## Invariants and settled scope

Originals are immutable: no rename, move, deletion, overwrite, silent same-name substitution or source writes. Device bookmarks and paths are permission/location hints, not identity. Unknown, denied, missing, unverified, residency and transfer states stay distinct. Off/metadata-only selection must not silently hash/read headers/preview/decode/hydrate content.

Cloud-hosted canonical project documents are MVP, not optional portability. Durable show/library/episode/collection/correction/history semantics survive index/cache rebuild. Autosave is **ON/configurable/OFF**, with explicit Save and honest dirty/recovery/conflict/offline/cancel states. Never acknowledge persistence without coherent disk truth or assume provider atomicity. Unknown-newer formats refuse edit/save; interrupted publication/migration retains recoverable prior work.

Speech analysis is local and **selected-primary only**; backups remain referenced. Human acceptance is mandatory for contextual filler suggestions. One episode edit map applies to every track for safe shortening, with editable timing-preserving lift alternatives, partial inverses, versioned boundaries/fades, preview and undo. No override can waive meaningful, other-primary, protected or intelligible crosstalk speech. Uncertainty means review/manual/abstain, not silent destructive acceptance.

M4 exports one common-origin cleaned speaker stem per speaker with coherent rate/map/duration/integer boundaries/silence padding, plus an editable reconstructive record and explicit original/recipe/asset requirements. Stems alone are not reversible. **48 kHz/24-bit PCM WAV** is the configurable default; feasible source-derived settings remain allowed. No mandatory portable copies, native DAW session, mixing/mastering, pause cleanup, plugin system, custom model training or mandatory diarization.

No engine, framework, file/package/JSON/SQLite or renderer is adopted by this publication. Preserve all numeric quality gates and controlled pre-holdout calibration. Retain **2/6 falsely accepted acoustic clock negatives**, native **OFF/nil risk**, **unexecuted merged-fade final-footprint risk**, tokenizer network fallback and every closed-batch raw denominator/failure. Historical finite passes are not generalized runtime support.

## Orchestration and execution

Start the actual repository **Squad** custom agent, load its roster/routing/charters and use **orchestrate**, not a coordinator impersonating domain specialists. Keep the lean existing roles: Lead, Mac, Design, Alignment, Pipeline and built-in Scribe/Ralph/Rai/Fact Checker. Do not install plugins, regenerate catalogs/casting, change global configuration or create auto-agent automation.

Every concrete writing unit gets **one app-native isolated worktree/session/branch/PR**. Begin from fresh main by omitting `base_branch`, except an explicit dependency/stack. Bound concurrent work to **4 live writer sessions + 1 coordinator + 1 independent reviewer**, counting nested agents; use fewer when work is not independent. Pure read-only expertise can use task agents within the same budget. Writer children do not launch additional writers. Parent/Scribe owns shared planning/decision documents; children own disjoint code surfaces and report proposed shared-doc updates. Never overlap edits in a checkout or touch a parent's main checkout.

At most **3 simultaneous native builds**, each `xcodebuild -jobs 4`, with isolated DerivedData/output and serial tests per lane unless the established runner supports safe isolation. The currently observed **18 cores / 128 GiB** host is ample but is not reference-device proof. Recalculate load when the host/workload changes; do not let every suite independently consume all cores. Use established project commands once created; restore dependencies only for changed manifests or an actual missing-dependency failure, retaining configured registries.

Before each shell invocation load `source "$HOME/.shell/exports-core.sh"`; for SSH push also load `source "$HOME/.shell/exports.sh"` for the existing agent. Use the existing configured GitHub.com identity, never invent credentials/email or alter global Git configuration. Add the repository-required Copilot co-author trailer to commits. Use `create_pull_request` for this session's PR, not `gh pr create`; use `create_issue` for new issues, not `gh issue create`.

Resolve ordinary engineering choices autonomously inside accepted scope. Try up to **3 distinct, evidence-informed approaches** before internal escalation to Lead/appropriate specialist; do not loop, rerun closed research blindly or quietly weaken criteria. Keep correcting failures, review findings and conflicts until the increment is usable, not just scaffolded or one issue closed. Independently review actual changes and run applicable checks before merge; never self-certify independent review. Preserve dirty user work; use no stash/reset/destructive cleanup as a shortcut.

## Permission boundaries

Pasting a named kickoff authorizes that milestone's repository code/build/test, dependency restores for changed manifests or verified missing dependencies, isolated branches/worktrees, commits, push, independently reviewed PR merges and relevant GitHub issue updates. It does **not** authorize recording inspection/processing, model body downloads/native asset provisioning, provider/cloud/network trials, GUI/OS settings, signing credentials or external podcast publication.

For future M1 engineering, this includes minimal ordinary native **build/test CI** declared as M1 code, including `.github/workflows`. It does not include repository/permission settings, auto-Squad dispatch, deployment/upload/release automation or signing credentials. The documentation-publication session itself remains **docs-only with no workflow changes**; do not carry that phase-specific workflow ban into future authorized build/test work.

Ask only when genuinely needed: exact media/provider/model assets, native provisioning/credential/GUI/destructive action, inaccessible required artifacts or an unresolved product-scope conflict. Request precise scope/destination/consequence and continue independent work. Do not reopen the 20 settled Q01-Q10 facets or ask for routine technical choices. Source downloads default ON in-app are not permission for an agent to inspect original samples. No external services receive recordings. Model/runtime availability stays UNKNOWN until actually observed. Public-signing/reference-device/broader participant work does not block safe internal use under the user's explicit split, but blocked core safety does.

## Bugs, issue closure and milestone exit

Classify required gates and **P0 must-now** failures separately from nice-to-have follow-ups. Deduplicate each new bug with GitHub search before using `create_issue`. A follow-up needs an issue, accountable informational owner, severity, acceptance criteria and next milestone; public-release-only items belong to Release, not an invisible TODO. Do not transfer an invariant, data-loss, source-write, protected-speech, offline/privacy or essential accessibility failure just to declare completion.

Close an issue only with acceptance proof or an explicit approved transfer linked to its receiving issue. The increment must be **actually demonstrable and usable**, all required issue acceptance must pass, and no open core-workflow/safety failures may remain. Close the milestone only when required work is done; historical completion and merged scaffolding are insufficient.

At exit, publish `docs/planning/milestone-exits/m1.md` (then m2/m3/m4 analogues) through a reviewed PR with:

- exact app/revision/host and a repeatable demonstration; required issue/evidence links and actual check/reviewer results;
- calibrated/frozen thresholds, observed measurements, honest unsupported/runtime limits and retained failures;
- bugs/follow-ups with owner/severity/acceptance/next milestone, plus exact asset permissions and remaining user-required inputs;
- current GitHub milestone URL, changed-file links and a **ready-to-copy next-milestone user kickoff**.

For M1 exit, write `docs/planning/kickoffs/m2.md` using [the M1 prompt](kickoffs/m1.md) as the authorization/orchestration template, replacing scope with M2 and including the actual M1 exit evidence, updated main commit, issue mapping and consent gaps. Subsequent exits produce m3/m4/m5 and, after M5, a separately permissioned Release prompt. Do not publish a fictional completion or pre-authorize recording access.

After independently reviewed merges, keep the coordinator's own main workspace updated safely (fast-forward only when its user changes permit it); isolated worktrees stay isolated. Never switch, stash or reset the parent's checkout. **Stop at the milestone boundary; never automatically start the next milestone.**
