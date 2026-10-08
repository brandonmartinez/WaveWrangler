# M3 review task and acceptance matrix

**Owner:** Design · **Status:** proposed documentary acceptance plan; no native task or human evidence is claimed.

**Refs:** [WW-025 (#22)](https://github.com/brandonmartinez/WaveWrangler/issues/22) · [WW-044 (#48)](https://github.com/brandonmartinez/WaveWrangler/issues/48) · [WW-029 (#26)](https://github.com/brandonmartinez/WaveWrangler/issues/26) · [Transcript and edit review spec](transcript-review-spec.md) · [M3 kickoff](../../planning/kickoffs/m3.md)

This matrix makes the proposed interaction testable. All rows are **Not run** in this documentation-only PR. A passing design review, text-level test, pure-state test, or synthetic fixture is not native keyboard/AX/VoiceOver proof, human comprehension evidence, or M3 completion.

## 1. Core task matrix

| ID | User task | Starting condition / fixture | Required completion and observable result | Essential access |
| --- | --- | --- | --- | --- |
| RV-01 | Identify the selected Primary and its Backups | Synthetic episode with two speakers, one Primary and one or more Backups each | Correct speaker/source/channel and role are visible and announced. Backup stays "not analyzed"; no automatic promotion occurs when Primary is unavailable. | Keyboard and VoiceOver; list/table alternative |
| RV-02 | Resolve a missing or blocked Primary | Primary variants: missing, offline/cloud-only, access denied, unknown availability | Exact observed reason is announced; analysis/audition/edit actions are blocked; the existing Setup remedy is reachable; no backup is substituted or implicitly downloaded. | Keyboard and VoiceOver blocked-state path |
| RV-03 | Inspect transcript text and timing | Synthetic transcript with complete, partial, absent, stale, and out-of-coverage timing | Timed values show explicit units/frames. Untimed content has no fabricated time/pin. Partial counts and stale/missing reasons are distinct. | Keyboard, VoiceOver, numeric/list alternative |
| RV-04 | Follow a word across transcript, timeline, and inspector | Linked panes with multiple occurrences and proposals | Selected occurrence/token/proposal stays consistent; linked highlight/playhead updates; text caret and focus owner do not move unexpectedly. | Keyboard and AX selection/focus assertions |
| RV-05 | Inspect a proposal without applying it | Pending, ambiguous, stale, and protected-overlap proposals | No cut is applied by analysis or selection. Evidence basis, exact interval, mode, protection, and disabled-action reason are readable. | Keyboard, VoiceOver, no color-only state |
| RV-06 | Accept the default safe cut | Fully timed synthetic candidate with no protected overlap | Accept applies one per-cut Shorten edit only after safety checks; history names the target; downstream times move earlier by the exact omitted duration. | Keyboard/menu path; Return/Esc behavior |
| RV-07 | Choose timing-preserving Lift | Same candidate plus case with protected speech inside the proposed range | Lift preserves the later output time with an explicit gap. Protected frames remain present and outside omitted/fade ranges; split eligible intervals are shown before accept. | Numeric/list control; keyboard and VoiceOver |
| RV-08 | Adjust a boundary and fade | Synthetic cut adjacent to retained unprotected audio and one invalid/protected fade | Exact frame entry and one-frame nudge work. Illegal ranges/fades are refused with reason; valid changes are one named undoable action. | Numeric alternative; no drag-only operation |
| RV-09 | Reject, restore, undo, and redo one cut | At least two accepted/pending cuts in the same episode | Reject creates no edit. Restore recovers the exact accepted boundary/mode/fades without source mutation. Undo/redo affect only the named action and its stale dependents. | Keyboard/menu Edit commands, history announcement |
| RV-10 | Audition a selection while text entry owns focus | Focused text field/editor with a non-empty value and known caret | Audition is explicit via labelled transport/menu; value/caret remain unchanged. Space/Return do not accidentally play, stop, accept, or alter a cut. Stop is reachable without Escape or dragging. | Keyboard and VoiceOver transport |
| RV-11 | Review the full common preview | Synthetic multi-speaker/multi-primary episode with Shorten and Lift cuts | Entire episode previews through one common map revision; all lanes share boundaries/timing; preview and internal render agree; stale/mismatched lanes block publication. | Keyboard/AX transport and numeric/list progress |
| RV-12 | Recover from stale source, Primary, transcript, or map | Change each input after analysis; include stale preview/render | Each distinct reason is shown; old result remains inspectable but cannot be accepted as current; the correct reanalysis/Alignment remedy is offered. | Keyboard and VoiceOver blocked-state path |
| RV-13 | Abstain safely | Unrecognized, untimed, unmapped, gap-crossing, or fully protected candidate | Audio remains uncut; exact reason is retained. No guessed timing, protection override, or required edit is introduced. | Keyboard/menu action; state readable without color |
| RV-14 | Correct transcript wording | Editable synthetic token with a known caret, timing, protection, and dependent proposal | Text correction is a named undoable transcript-only edit; audio and timing are unchanged unless tokenization makes timing ambiguous. Dependent proposals become stale; existing protection is not cleared. | Keyboard and VoiceOver; preserve caret/focus |

## 2. Measurable acceptance gates

The following gates are proposed for owner/domain review and must be tied to exact implementation revisions and test evidence. They are not results of this PR.

### Safety and edit semantics

- **0** analyses of a Backup or source outside the approved selected-primary set; **0** automatic Primary substitutions; **0** implicit network/hosted speech fallback.
- **0** accepted cuts that remove or attenuate a protected source frame, cross an occurrence/epoch/map gap, use missing timing, or rely on stale source/Primary/transcript/map state.
- **100%** analysis-created proposals begin unapplied. Accept/reject/adjust/restore/abstain are per-cut, versioned, and named in history.
- For each synthetic Shorten case, later output timing advances by the exact removed source duration under the common map. For each Lift case, later output timing is unchanged and the output gap has the exact reserved duration.
- Preview and internal render use the same edit-map revision and agree on per-cut source-frame boundaries, mode, fade, channel identity, and resulting output times for the complete synthetic multi-lane episode. A mismatch blocks publication.
- **0** source mutations in the synthetic source-immutability checks. Every stale/missing/blocked test has a distinct readable reason and a safe remedy or an explicit "no safe action" result.

### Essential accessibility and native interaction

- **100% of core tasks RV-01 through RV-14** have a usable keyboard path with visible focus and a non-drag route. Every command needed to complete them is discoverable through the menu bar or a labelled focusable control.
- **100% of changed essential controls and states** expose the expected native role, label, and value; run the required `elementDetection`, `sufficientElementDescription`, `hitRegion`, and `action` audits on changed surfaces. Run `.contrast` on blocked/recovery surfaces. Any essential failure blocks the UI PR.
- **0** accidental text changes or caret/focus loss in RV-04/RV-10/RV-14; **0** custom shortcut interception of Space/Return while text entry owns focus.
- Every blocked/recovery state is reachable and its reason/remedy is legible and exposed to AX; **0** color-only, waveform-only, sound-only, or drag-only tasks.
- A documented automated AX/keyboard path does not substitute for a human VoiceOver listening result. The M3 essential gate is not evidence for M5's broader VoiceOver/FKA/system-setting, 200%-text, contrast, reduced-motion, or reference-device qualification.

### WW-029 usability evidence

WW-029's current issue text carries provisional targets of **at least 80% unassisted task success**, **at least 90% state-and-mode comprehension**, and **median recovery no more than 2 minutes**, plus zero lost work, unexpected/disabled/cancelled/unconsented downloads, or overlap loss. Preserve those values as issue-owned proposed criteria; this document reports no measured results and does not lower or claim them. Before any human task run, the owner must define the task denominator, participant permission, facilitator/script, success coding, calibration/holdout split, and recording/retention limits in the appropriate approved protocol. Do not use sensitive transcript/media content as evidence. Broad participant/reference-device qualification remains separate; essential core keyboard and accessible blocked/recovery paths are non-deferrable.

## 3. Evidence classification and required review record

| Evidence class | What can satisfy it | What it does not establish |
| --- | --- | --- |
| Documentary contract | This spec, review matrix, issue text, and written domain decisions | Implemented behavior, a usable native accessibility tree, or human comprehension |
| Pure-state / synthetic tests | Exact edit-map arithmetic, protected-frame refusal, stale invalidation, source-immutability checks, deterministic task fixtures | Native focus, actual speech/audio quality, primary media timing, VoiceOver listening, or participant success |
| Native automated UI evidence | Exact-head native UI tests for task paths, keyboard focus, AX labels/values/audits, disabled reasons, text-entry-safe audition, and recovery; report SHA, host, classes, counts, and retained result bundle | Broad VoiceOver listen, participant comprehension, reference devices, untested state combinations, or unsupported media |
| Human review evidence | Approved bounded tasks with measured task denominator, comprehension/recovery scoring, permission, conditions, and aggregate-only results | Other recordings, backups, cloud providers, general population claims, or M5 qualification beyond the tested envelope |
| Native/manual accessibility evidence | The exact permitted manual checks, host/OS, tasks, and observed outcome | A design specification or automated AX audit alone cannot stand in for the manual check |

PR and milestone records must mark each evidence cell Pass, Fail, Not run, or Not applicable, with an exact revision and a link to the evidence. Failed, skipped, blocked, interrupted, and incomplete runs remain distinct. A synthetic-only pass does not satisfy primary-media timing, a native audit does not satisfy a human study, and an M3 internal result does not qualify M5.

## 4. Requirement trace and status for this PR

| Issue | Required outcome addressed by these documents | Status here |
| --- | --- | --- |
| WW-025 (#22) | Selected Primary/Backup behavior; missing, stale, and uncertain timing; linked transcript/list/timeline/inspector; non-fabricated proposal evidence; human review and complete preview | **Specified; not implemented or validated** |
| WW-044 (#48) | Shorten-when-safe default; editable timing-preserving Lift; protected overlap refusal; per-cut boundary/fade; accept/reject/adjust/restore/named undo; common map and preview | **Specified; Pipeline/Alignment/Mac review and native evidence pending** |
| WW-029 (#26) | Core task matrix; measurable safety and essential accessibility gates; clear separation of documentary, synthetic, native, and human evidence | **Protocol and evidence not run; no qualification claim** |

This docs-only PR adds no code, app state, issue closure, media evidence, or milestone acceptance. Its reviewable evidence is the source-linked interaction contract and the explicit, unrun task/acceptance matrix above.
