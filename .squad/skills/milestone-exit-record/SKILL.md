---
name: "milestone-exit-record"
description: "Use when writing a WaveWrangler milestone exit record (docs/planning/milestone-exits/mN.md) and the issue closure-proof comments. Write the record ONCE, after the last P0 merges, from this template (at most 250 lines). Does NOT replace the evidence itself, and never fills a gate that wasn't measured."
domain: "documentation, milestone exits"
confidence: "medium"
---

# Milestone exit record

M1's exit record was drafted from hour 4, churned through 48 commits and cost about 10% of the run (`docs/planning/retrospectives/m1.md` §3 #7). From M2: write it once, after the last P0 merges and the final gate runs, in one pass. No running drafts, no placeholders like `<<PENDING>>` in a merged record. If a gate can't run, say so plainly as a blocker with its cause.

## Closure-proof comment (each required issue, as soon as its proof merges)

```text
Closure proof — WW-0NN
- Merged: #PR (SHA abcdef1)
- Host: <host name, macOS, Xcode>   (or "CI macos-26" for headless-only proof)
- Checks: <command> → <counts>; CI <run link>
- Evidence: <link to the gate section / evidence note>
- Criteria: <each acceptance criterion> → met / transferred to #N (approved by <who, when>)
```

Close the issue right after posting. Never close on partial evidence; never transfer an invariant.

## Template (≤250 lines)

```markdown
# MN exit record — <milestone name>

**Record date:** · **Owner:** Lead · **Milestone:** <link> · **Acceptance issue:** <link> · **Next prompt:** [MN+1 kickoff](../kickoffs/mN+1.md)

**Status:** <passed | not passed: reason>. One sentence, honest.

## 1. Revision and host
Final main SHA, app build, hosts (dev Mac and GUI hosts with macOS/Xcode/hardware), CI image.

## 2. Repeatable demonstration
Numbered steps a user can repeat on synthetic fixtures; what the consented media validation covered (no paths or content).

## 3. Required issues
| WW ID | Issue | Result | Proof (PR, SHA) |

## 4. Exit gate
| Gate | Result | Evidence |
Full UI suite (SHA, host(s), shard map, pass/fail/skip, xcresult location) · scripts/test.sh counts · exit checkpoint on its own line (in-app 200% text, light/dark) · performance gates vs baseline · essential audits vs the pinned waiver baseline.

## 5. Frozen gates and holdouts
| Gate | Freeze ID / date | Counts | Calibration result | Holdout result (nearest-rank p95, max) |

## 6. Supported envelope and limits
What is supported (evidenced only) and what is not; runtime and host limits.

## 7. Retained failures and risks
Carried, not hidden.

## 8. Bugs and follow-ups
| Issue | Severity | P0 must-now / follow-up | Owner | Next milestone |

## 9. Permissions used and remaining user inputs

## 10. Process deviations (disclosed)

## 11. Links
Milestone, PRs, changed files.
```

Evidence budget: one short section per gate; link to raw records instead of pasting them; no screenshots or crops unless a finding cites them.
