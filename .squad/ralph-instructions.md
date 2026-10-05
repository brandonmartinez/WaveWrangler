# Ralph Instructions
<!-- User-owned: customize this file to override Ralph's autonomous-execution behavior.
     squad init creates this file on first install; squad upgrade never overwrites it. -->

<!--
  PURPOSE
  -------
  When `.squad/ralph-instructions.md` exists, `squad watch --execute` instructs the
  spawned Copilot session to read this file and follow ALL sections here instead of
  the built-in fallback prompt.  If the file is absent, the built-in prompt is used.

  CONTRACT (stable — safe to build on)
  --------------------------------------
  YOU CAN  customize via this file:
    • Extra instructions given to Ralph at session start (Teams/Slack notifications,
      calendar checks, post-task hooks, MCP-powered side effects, escalation paths)
    • Additional eligibility rules or priority ordering for issue selection
    • Agent persona, tone, or verbosity for session output

  YOU CANNOT override via this file:
    • Parallelism — Ralph always spawns agents for all actionable issues simultaneously
    • Core eligibility filter (squad/squad:* label required, not blocked, not assigned)
    • The underlying `gh` / Copilot CLI command used to spawn each session

  TRUST IMPLICATIONS
  ------------------
  This file is read by the spawned Copilot session with full agent permissions.
  Treat it like code — never paste untrusted content here.  Anyone with write access
  to this file can influence what the agent does on your behalf.

  If this file is missing or empty, `squad watch --execute` falls back to the
  built-in prompt with no behavioral change.

  PLACEHOLDERS
  ------------
  The following values are injected by execute.ts before the session reads this file:
    (none currently — Ralph builds the issue list dynamically at runtime)

  FORMAT
  ------
  Plain markdown.  Structure with ## sections.  The spawned session reads the whole
  file, so keep it concise — one screen of instructions is ideal.
-->

## WaveWrangler manual milestone operation

Follow `docs/planning/milestone-runbook.md` and the user's named milestone kickoff.
Do not start `squad watch --execute` as a substitute for the bounded app-native milestone coordinator.
The watch command's built-in eligibility/parallelism cannot be safely restricted by this instruction file alone.
If invoked without an explicit current-milestone authorization, report the missing scope and do not implement or spawn writers.

### Issue Selection

Inspect only the authorized milestone. Use live issue acceptance/dependencies and informational `owner:*` labels.
Do not add `squad`/`squad:*` dispatch labels or select work from later milestones.
Report blockers and owned follow-ups to Lead; a dependency blocks acceptance, not unrelated safe preparation.

### Post-Task Actions

<!-- Uncomment and customize to add post-task hooks, e.g. Teams notifications:

After completing work on each issue:
- Post a brief summary to the team channel via your Teams MCP tool.
- Update the issue with a progress comment if no PR has been opened yet.
-->

### Escalation

A blocker affects dependent work only. Continue independent authorized work and escalate routine engineering internally.
Ask the user only for genuinely required input or permissions; never bypass source/durability/privacy/protected-speech gates.
At milestone completion produce the exit and next kickoff, then stop; do not begin the next milestone automatically.
