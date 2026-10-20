# WaveWrangler development

- Work directly from the user's current request. Do not restore retired team
  orchestration, milestone kickoffs, or issue-dispatch automation.
- Use American English for first-party identifiers, comments, documentation,
  and interface text. Preserve platform API names, third-party source bytes,
  existing serialized keys, and quoted historical evidence.
- Use Swift 6 concurrency and isolation, value types for domain state, and
  small focused types. Prefer composition and existing shared helpers over
  inheritance, duplicated logic, or speculative abstractions.
- Keep original recordings immutable. Preserve explicit source authorization,
  local-only inference, verified saves, schema compatibility, and Undo/Redo.
- Use established build/test commands and bounded worker counts. Keep the
  editing app's DerivedData separate from test builds.
- Prefer the macOS VMs for UI tests. An unavailable VM is a blocker, not
  permission to fall back to the Mac mini or the user's desktop. Use a physical
  host only for a requirement that cannot be meaningfully verified in a VM,
  explain why, and obtain approval for the specific run.
- Historical planning and research record prior decisions and measurements;
  they do not authorize new work, commits, pushes, merges, or media access.
