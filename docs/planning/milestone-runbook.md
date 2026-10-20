# Development workflow

Development is directed by the current user refinement session. The Squad
milestone orchestration, copied kickoff permissions, specialist ownership,
and issue-dispatch process were retired on 2026-10-20.

- Use the [engineering guide](../engineering/README.md) for code layout and
  existing build/test commands.
- Use American English for first-party code, comments, documentation, and UI.
  Keep platform names, serialized formats, third-party sources, and quoted
  historical evidence compatible.
- Prefer focused types, value semantics, explicit Swift concurrency isolation,
  composition, and shared logic where it actually removes duplication.
- Prefer the [macOS VMs](../engineering/ui-test-vm-hosts.md) for GUI work and
  follow the [lease pipeline](../engineering/gui-testing.md). A physical-host
  exception requires a concrete limitation and approval.
- Preserve immutable originals, source authorization, local inference, verified
  saves, recovery, Undo/Redo, and essential keyboard/accessibility behavior.
- Commits, pushes, merges, model/media access, and physical-host runs require
  their normal explicit authorization; old kickoff text grants none.

At the user's explicit request, all 90 open GitHub issues were permanently
deleted. Completed issues and pull requests were left unchanged. The old
[backlog index](github-backlog.md), [mapping](github-backlog.json), and research
remain historical references, not a live work queue or completed-product claim.

Old milestone kickoffs and coordinator handoffs are available in Git history,
not as current development instructions.
