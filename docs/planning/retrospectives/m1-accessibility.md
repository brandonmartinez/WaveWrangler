# M1 accessibility testing retrospective

**Source:** a read-only analysis of M1 accessibility testing, prepared for the user and supplied to the M2 coordinator on 2026-10-06; sanitized for publication (no media content or local session identifiers). Times are UTC. *Inference* marks estimates from gaps between GUI-lock releases (upper bounds). Companion: [M1 process retrospective](m1.md).

## Corrections and decisions since the report

- **#154 was retracted** (closed as not planned; not a defect). The original report counted it as the only accessibility-attributable P0 (data loss). That claim is withdrawn: in M1 the keyboard core-task tests found **P1** product bugs, not a P0.
- **The recommendation was adopted** (user, 2026-10-06 01:20): milestone **M5 — Accessible MVP qualification** (milestone 7) with WW-053 ([#167](https://github.com/brandonmartinez/WaveWrangler/issues/167)) owns broad accessibility. WW-052 depends on WW-053. [#147](https://github.com/brandonmartinez/WaveWrangler/issues/147) (user-manual items) moved there.
- **The exit checkpoint is in-app 200% text plus light/dark only.** System Increase Contrast is not in it (that's M5). Text-size checks don't run per PR.
- **Essential audits and performance are exit gates against a pinned waiver baseline**; per-PR runs fail only on new findings.

## Bottom line

- **Keyboard core-task tests paid for themselves:** they found #86, #114, #155, #156 and #66/#125 (P1 product bugs, several of them honesty or durability bugs rather than accessibility).
- **Broad visual checks were mostly churn.** Text size, contrast, Increase Contrast, Reduce Motion and automated VoiceOver found only P1-or-lower polish (#109, #138, #126, AccentColor, #59) and **no P0**. They took about 6–8 h of GUI-host time (*inference*, ~35–45% of GUI-busy time) and ~15–20% of model usage.
- **Recommendation (adopted):** split accessibility into **essential checks in every milestone** and a separate broad-qualification milestone (M5) after M4, once the UI has settled.

## 1. Inventory

| Check (spec ID) | Tests | Cadence in M1 | GUI time (*inference*) | Real findings | Noise / harness |
|---|---|---|---|---|---|
| Pure-logic A-01…A-08 | Unit tests in `scripts/test.sh` | Every PR | 0 | Guarded wording and state honesty | None |
| A11Y-004 static source audit | `static_audit.py`, 132 controls | Once | 0 | 0 flags | **Missed #110**; heuristic only |
| XCUITest `performAccessibilityAudit` per surface | `AcceptanceAudit.run` in 4 suites, ~45 tests | Every GUI run of every UI PR | Mixed into ~80 lock windows; the contrast part drove the #57 loop (9 runs), #98 T13 reruns and #113 (7 runs) | #110 (P1), sidebar AX values in #57 | **~147 waivers** (occlusion, clipped cells, Touch Bar, modal dim, third-party overlay, two-process launch #135) |
| C01 keyboard-only core tasks T01–T30 | `CoreTasksKeyboardUITests`, `SheetKeyboardUITests`, lane steps | Lane PRs, WW-007 batch, closeout | ~1.5 h | #86, #114, #155/#156, T16 → #66/#125 (all P1) | REF-020 click-selection harness defect; test pollution #163/#165 |
| C02 VoiceOver (automated) | `VoiceOverWalkUITests` (3) + a computer-use attempt | 3 attempts | ~1 h | **0 announcements captured** | All noise; now manual (#147) |
| C03 text size 200% | 4 tests | WW-007 batch, #113 loop, re-measurement, exit leg | ~2–2.5 h | #109 (P1 overflow), #89 check | 1-pt border failures; **system larger text doesn't change AppKit fonts** |
| C04 Increase Contrast / C07 light-dark | `ContrastEvidenceUITests` (7), `SelectionContrastUITests` (1) | 4 Design slots, #139, exit leg | ~2–2.5 h | AccentColor 4.02 → fixed; #138 (IC only); #126 (P1 alert on recovery/refusal); #59; #100 | IC override didn't emulate system IC; settings snapshot/restore ceremony |
| C05 Reduce Motion | System setting + `-WWForceReduceMotion` | 2 runs | Small | None (motion isn't observable in static captures) | Now manual |
| C06 saturation 0 | 1 test | 2 runs | Small | Pass | None |
| Full Keyboard Access | None (agents may not toggle it) | Never | 0 | n/a | User-manual (#147) |
| Window zoom/resize | Setup/Library suites | Lane PRs | Under audits | **#129 P0 crash**, #104, #140 | UI robustness, not accessibility |

## 2. What found what

- **Essential checks** (keyboard task paths, AX labels and roles, recovery-state legibility) found about 7 P1 product bugs for about 2.5 h of GUI time: **highest value per hour.**
- **Broad visual matrices** (C03, C04/C07, C05, C06) found about 5 real P1/P2 polish issues and 0 P0, for 5–6 h of GUI time spent mostly separating artefacts from findings. Surfaces kept changing, so measurements went stale.
- **Automated VoiceOver and Reduce Motion:** zero yield. These are human checks.
- **Root cause:** spec §6.4 made "any Fail in an essential task" under any condition a P0, and §6.2 required full C01–C07 matrices, which turned visual polish into milestone gates.
- **Window zoom/resize** found the only P0 in this area (#129, a crash) — a robustness check worth keeping in the per-window smoke pass.

## 3. Essential vs broad

**Essential (every milestone; product invariant):**
1. Every core task is keyboard-only operable: visible focus, Return/Esc on sheets, menu equivalents.
2. Every control has an AX role, label and value (audit types `.elementDetection`, `.sufficientElementDescription`, `.hitRegion`, `.action`; `.contrast` only on blocked/recovery surfaces).
3. Every blocked, error or recovery state is reachable, labelled and legible (system colours or opaque material, as in #126).
4. No colour-only state and no drag-only interaction.
5. Pure-logic A-checks (wording, honest state, shortcut register, defaults).

**Broad (M5 / WW-053):** 200% text, Increase Contrast and light/dark matrices with glyph measurement; Reduce Motion; VoiceOver listening; Full Keyboard Access; saturation 0; the zero-unwaived `.contrast` baseline; colour polish; system larger text.

**Design-for rules** (per PR, to avoid structural rework before M5): semantic fonts and colours; reflowable containers (no fixed-height text containers); constant column ideal widths (never add/remove columns on resize).

## 4. Cadence adopted for M2–M4

| When | What | GUI budget |
|---|---|---|
| Each PR that touches UI | Essential items 1–4 for the changed surfaces only | Within the PR's affected-class run, ≤5 min |
| Each PR | A-checks plus static audit in CI | 0 |
| Capped full suite (~3 h / 4+ merges) | Essential audits inside the suite; only **new** findings vs the pinned baseline are reported | No extra slot |
| Each new window lands | Smoke pass: essential checks plus window zoom/resize, recorded briefly on the window's PR (Design) | ≤30 min |
| Milestone exit | Checkpoint: in-app 200% text plus light/dark on the milestone's windows, reported on its own line. Blocks only if a core task becomes impossible; the rest go to WW-053 | One slot, ≤30 min |
| Never by agents | VoiceOver listening, Full Keyboard Access, Reduce Motion by eye | User-manual list (#147) |
