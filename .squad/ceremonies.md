# Ceremonies

> Team meetings that happen before or after work. Each squad configures their own.

## Research Framing

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | before |
| **Condition** | research topic spans two or more specialist domains |
| **Facilitator** | lead |
| **Participants** | all-relevant |
| **Time budget** | focused |
| **Enabled** | ✅ yes |

**Agenda:**
1. State the decision or uncertainty to retire
2. Separate known facts, assumptions, and open questions
3. Assign domain research without overlapping ownership
4. Define evidence, measurable success criteria, and handoff format

---

## Architecture Synthesis

| Field | Value |
|-------|-------|
| **Trigger** | manual or milestone |
| **When** | after |
| **Condition** | a research batch is complete or a staged-plan decision is due |
| **Facilitator** | lead |
| **Participants** | all-relevant, Fact Checker, Rai |
| **Time budget** | focused |
| **Enabled** | ✅ yes |

**Agenda:**
1. Compare viable options and constraints
2. Review interfaces across macOS, DSP, and editing semantics
3. Run a pre-mortem and privacy/consent review
4. Record build/buy/defer decisions, risks, experiments, and acceptance criteria
5. Confirm the named milestone kickoff supplies engineering authorization; do not ask for a second generic approval

---

## Retrospective

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | after |
| **Condition** | failed experiment, contradicted claim, reviewer rejection, or planning dead end |
| **Facilitator** | lead |
| **Participants** | all-involved |
| **Time budget** | focused |
| **Enabled** | ✅ yes |

**Agenda:**
1. What evidence changed?
2. Which assumption failed?
3. What should change in the plan or experiment?
4. What follow-up retires the remaining uncertainty?


---

## Retrospective with Enforcement

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | weekly |
| **Condition** | No *retrospective* log in .squad/log/ within the last 7 days |
| **Facilitator** | lead |
| **Participants** | all |
| **Time budget** | focused |
| **Enabled** | yes |
| **Enforcement skill** | retro-enforcement |

**Agenda:**
1. What research questions were retired?
2. What remains open or blocked?
3. Which assumptions or experiments failed?
4. Record owned follow-ups with explicit completion evidence.

**Coordinator integration:**
Evaluate retrospective follow-ups at the milestone exit using the available project skills and exit evidence. Published milestone retrospectives live in `docs/planning/retrospectives/` (M1: `m1.md`, `m1-accessibility.md`); a new milestone's first Squad-config PR applies them.
An absent machine-local log is not proof that a new worktree is overdue. Do not install missing enforcement tooling or block coding on a full-team ceremony.
Ralph tracks resulting issues; Lead retains milestone priority and decision authority.

---

## Kickoff Preflight

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | before |
| **Condition** | a named milestone kickoff starts, or before the first GUI or remote run |
| **Facilitator** | coordinator |
| **Participants** | none (coordinator checks) |
| **Time budget** | ≤15 min |
| **Enabled** | ✅ yes |

**Agenda:** run `.squad/skills/kickoff-preflight`; record PASS/FAIL per item in the coordinator's first status; send ONE consolidated user ask for user-only items; continue all work that needs neither the user nor a blocked host.

---

## Away-Window Ask

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | before |
| **Condition** | the user has stated an away window, or is known to be away |
| **Facilitator** | coordinator |
| **Participants** | none |
| **Time budget** | one message |
| **Enabled** | ✅ yes |

**Agenda:** collect every pending user-only action (consents, sudo steps, unlocks, manual checks, gate questions with data) into a single message with exact scope and consequence. During the window the user keeps 1Password unlocked and Focus/Do Not Disturb on, on the GUI hosts.

---

## Window Smoke Pass

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | after |
| **Condition** | a PR adds a new window, panel or sheet |
| **Facilitator** | design |
| **Participants** | the authoring lane |
| **Time budget** | ≤30 min GUI, on the Mac mini |
| **Enabled** | ✅ yes |

**Agenda:** essential accessibility checks on the new surface plus window zoom/resize (zoom found M1's only P0 crash in this area, #129); record a brief result on the window's PR. In-app 200% text runs at the exit checkpoint; Increase Contrast and Reduce Motion are M5.

---

## Capped UI Regression Run

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | after |
| **Condition** | ~3 h of active merging or 4+ merges to main since the last full run (whichever first), and always on the exit SHA |
| **Facilitator** | coordinator (spawns the Regression runner lane) |
| **Participants** | Regression runner |
| **Time budget** | one build plus sharded GUI runs |
| **Enabled** | ✅ yes |

**Agenda:** one build-for-testing; the full `WaveWranglerUITests` suite (no filter) sharded by class across GUI hosts under each host's lock; full `scripts/test.sh` on the same SHA; record SHA, hosts, shard map, counts and xcresults. Any failure is a regression: triage, deduplicate, file with severity and P0/follow-up classification, freeze merges in that area until understood. Flaky failures are fixed or tracked, never silently re-run.

---

## Exit Checkpoint

| Field | Value |
|-------|-------|
| **Trigger** | milestone |
| **When** | after |
| **Condition** | the final main SHA of a milestone |
| **Facilitator** | design |
| **Participants** | Regression runner |
| **Time budget** | ≤30 min, inside the final full suite |
| **Enabled** | ✅ yes |

**Agenda:** in-app 200% text plus light and dark on the milestone's windows, reported on its own line in the exit record. Only a finding that makes a core task impossible blocks; the rest become WW-053 follow-ups. System Increase Contrast and Reduce Motion are not part of it (M5). Then write the exit record once ([skill](skills/milestone-exit-record/SKILL.md)).

---

## Child Cleanup Sweep

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | after |
| **Condition** | a substantive completed-unit handoff; about every 2 h of active work; at the final handoff |
| **Facilitator** | coordinator |
| **Participants** | none |
| **Time budget** | ≤10 min |
| **Enabled** | ✅ yes |

**Agenda (user-directed 2026-10-07 10:01/12:50; cadence updated 2026-10-09 20:34):** check relevant completed children at handoff and do a full sweep about every 2 h of active work or at final handoff, not on every idle notification. Before archiving verify PR merged or closed (or a superseded lane), no open PR, active Agent merge or session automation, clean fully pushed worktree, and `files/` notes copied to coordinator `files/archived-children/`. Archive only those that pass; skip open or in-flight work and report one concise count with reasons. Existing app `notify_on_idle` flags are not retroactively changed by this policy.
