# Manual Squad operations

All active Squad workflows use `workflow_dispatch` only.
There are no push, issue, pull-request or scheduled automatic triggers.

- Milestone and issue reports are read-only/advisory.
- Owner routing changes only informational `owner:*` labels.
- Label sync preserves the current priority/type/gate taxonomy; it creates no `squad` dispatch labels.
- No workflow assigns a GitHub coding agent or starts work across milestones.

Implementation starts through the named milestone kickoff and follows `docs/planning/milestone-runbook.md`.
Matching installed workflow templates are project-specific; preserve this policy during Squad upgrades.
