# Model Selection Reference

## Per-Unit Model and Effort Resolution

The task/diff-based table in [routing.md](../routing.md#model-tiers-for-new-sessions-and-task-agents) is the **single authoritative tier mapping**. Apply it to every NEW `create_session` and `task` call, not the coordinator's current model, the agent's title or an old role default. A specific current user model directive wins for its stated scope; otherwise select the actual unit's work from that table. Do not add unimplemented `defaultModel`, `agentModelOverrides` or effort keys to `.squad/config.json`.

1. Identify whether this unit actually changes a safety invariant or independently reviews such a change. Only that work and complex DSP get high capability/high or justified xhigh effort; a safety-related PR's deterministic log collector remains fast/low.
2. Routine UI, integration without changed safety semantics, docs/config, test/harness implementation and ordinary review use mid/medium. Cheap planning or triage can use `gpt-6-luna`/medium.
3. Prefer direct shell for <=5-call lookups and deterministic commands. If an agent is necessary for mechanical execution or parsing, use fast/low. A reviewer role, image inspection, structured prompt, coordination, or prior rejection **alone** never raises the tier.
4. Give fresh PR/unit sessions short, complete kickoff context: objective, owned paths, applicable invariant/permission decisions, dependencies, exact acceptance commands and stop. Do not inline entire milestone prompts, charters, histories or raw test logs. Keep safety review independent and rigorous.

## Fallback and Spawn Record

If a requested model is unavailable, try only the GPT fallback in the same table row, with the same effort. If it too fails, stop and report the blocker. Do not silently fall back to Claude, a different tier or an unspecified platform default. A Claude exception requires a separately recorded reason under the existing user preference; do not hot-switch running units. A safety review remains independent regardless of model.

Pass `model` and `reasoning_effort` explicitly in each supported spawn. Keep a small private session lane ledger: unit/role, session ID, requested model/effort, actual model **only when observable**, premium reason if any, and result. A requested model is not proof of actual use; do not estimate dollars from AI usage-unit counts.

For a deterministic long build/test, use a bounded shell/helper (or one fast runner) with SHA, selectors, timeout and concise terminal pass counts or exact failure tail. Reuse warm `.build`/DerivedData during iteration and exact-SHA GUI Products when valid; one fresh full `scripts/test.sh` on the exact code head remains required before merge. Docs/Squad-only changes retain their documented exemption. Let process/child completion notifications trigger the next decision; no model agents polling the same job.
