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
Evaluate retrospective follow-ups at the milestone exit using the available project skills and exit evidence.
An absent machine-local log is not proof that a new worktree is overdue. Do not install missing enforcement tooling or block coding on a full-team ceremony.
Ralph tracks resulting issues; Lead retains milestone priority and decision authority.
