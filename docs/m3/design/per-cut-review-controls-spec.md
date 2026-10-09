# M3 per-cut Review controls

**Owner:** Design
**Status:** proposed interaction contract; **not implemented, not native-validated, and not acceptance evidence**.
**Refs:** [WW-044 (#48)](https://github.com/brandonmartinez/WaveWrangler/issues/48) · [WW-025 (#22)](https://github.com/brandonmartinez/WaveWrangler/issues/22) · [WW-029 (#26)](https://github.com/brandonmartinez/WaveWrangler/issues/26) · [WW-043 (#40)](https://github.com/brandonmartinez/WaveWrangler/issues/40) · [WW-045 (#41)](https://github.com/brandonmartinez/WaveWrangler/issues/41) · [cut-policy protocol](../ww-027-cut-policy-protocol.md) · [review task matrix](review-task-matrix.md) · [transcript and edit review](transcript-review-spec.md)

This is the compact, testable native-control companion to the broader Review contract. It uses the existing `Review` destination name and `Cmd+3` navigation. It does not add a second window, a permission prompt, a backup-transcription path, or a production cut activation claim.

## 1. Current boundary and terminology

The merged [#272](https://github.com/brandonmartinez/WaveWrangler/pull/272) `WWCutPolicy` is a provisional pure-policy boundary. Its person-action and complete-lane constructors are non-public; it cannot publish to `WWCommonEdit`, invalidate preview/render, or expose a native review control. Its synthetic test result is not native keyboard, accessibility, renderer, word-time, media, or human-review evidence.

| Term shown in Review | Meaning | Current status |
| --- | --- | --- |
| **Analysis state** | Exact transcript/proposal dependency state: Ready, Pending, Stale, Blocked, or Unavailable, followed by its observed reason. | Proposed native presentation; policy has typed refusals but no app field/control. |
| **Default mode** | `Shorten when safe`, only when the current all-lane proof makes Shorten admissible; otherwise `No safe default`. | Proposed native presentation; no native default chooser exists. |
| **Shorten** | Remove the validated common output interval from every affected lane; all later output moves earlier by the one rounded common duration. | Policy semantics only; not renderer/app integration. |
| **Lift - preserve timing** | Reserve that same common output interval on every affected lane so later output time does not move. | Policy semantics only; never a protection waiver. |
| **Refusal** | A blocked action with a typed dependency reason, named lane when applicable, and a safe remedy or explicit “No safe action.” | Policy has typed refusals; native labels/remedies remain pending. |
| **Restore** | Deactivate one accepted cut in the common map while retaining its parameters and history; it never restores source bytes. | Journal semantics only; common-map publication remains pending. |

`analysisState`, `defaultMode`, and refusal text are literal visible and accessibility-readable labels in this contract, not inferred colors, icon-only badges, or undocumented property names. The app may localize their user-facing copy, but must retain their distinct meanings.

## 2. Per-cut inspector contract

Selecting one proposal/cut in the Review list, timeline, or numeric-list alternative selects the same logical proposal ID and opens its details in the existing inspector. Selection never accepts a cut. The inspector preserves its selected proposal while a dependency becomes stale so the person can read why the action stopped.

| Inspector element | Required visible/AX content | Availability |
| --- | --- | --- |
| Header | Proposal/cut ID, speaker, selected Primary source/channel, occurrence, epoch, and exact source-frame `[start, end)` range. | Always for a retained proposal/history entry. |
| Analysis state | Label `Analysis state`; Ready/Pending/Stale/Blocked/Unavailable plus exact reason and dependency revision(s). | Always. Unknown is stated honestly, never rendered as zero/ready. |
| Default mode | Label `Default mode`; `Shorten when safe` and common output-frame duration/rate only after current all-lane proof. Otherwise `No safe default — <reason>`. | Always. |
| Mode control | Radio group: **Shorten** and **Lift - preserve timing**. The unavailable choice remains visible with its reason. | Editable only while the proposal is current and the chosen mode can be independently proven. |
| Boundary controls | Integer Start/End source-frame fields, source rate/unit, original proposal bounds, one-frame stepper/nudge, and larger labelled increment. | Editable only within the original proposal's source-frame interval on the selected Primary occurrence/epoch; protected/unsupported subintervals cannot be accepted. |
| Fade controls | Explicit output-frame fade-out and fade-in fields, each defaulting to `0`; current final/merged footprint result. | Editable only after each affected lane proves supported, backed, unprotected retained fade frames. |
| All-lane proof | Every affected Primary, Backup, other-speaker, and intentional-silence lane: source/occurrence/epoch or silence interval; backing, map, protection, conversion, padding, and endpoint status. | Always as a list; unknown/uninspectable entries remain listed. |
| Actions | Accept, Reject, Adjust, Restore, Abstain; named history and Undo/Redo are in the standard Edit menu. | Exactly as state/dependency gates permit; disabled actions give a visible and AX reason. |

Display four distinct coordinates for each supported boundary, in the inspector, numeric-list alternative, and accepted-cut history: **Source time** (selected Primary's native frame/rate in its named occurrence), **Group time** (that occurrence's epoch clock), **Aligned time** (current M2 map coordinate), and **Output time** (post-edit common output frame/rate with the active edit-map revision). Show the exact pre-edit aligned-output-grid `[qStart, qEnd)` and rate `R` separately from post-edit Output time: `qStart` is not an accepted cut's output position. Recompute and label the history position after earlier accepted Shorten shifts and clock-map corrections; on a map or active-cut revision change, mark dependent coordinates/history Stale until recalculated, never retain a prior position as current. Where a coordinate is unsupported, show an explicit reason such as `No aligned time — gap/outside coverage`, `No source inverse — Lift gap`, `No output position — removed by Shorten`, or `Unknown — stale map/ambiguous inverse`, rather than zero, an arbitrary occurrence, or a fabricated timestamp. Show exact frame counts/rates and revisions alongside rounded display timecodes.

For example, in a synthetic 48,000-frame/s source and output with epoch offset `+1 s` and current M2 map `aligned = 1.001 × group - 0.100 s`, a proposal's selected-Primary Source `[480000, 528000)` frames is `[10, 11) s` Source, `[11, 12) s` Group, and `[10.911, 11.912) s` Aligned. Its endpoints land exactly on pre-edit grid `[qStart, qEnd) = [523728, 571776)` output frames. If an earlier accepted Shorten removed pre-edit `[3.000, 3.500) s` (24,000 output frames), the **pending proposal's post-edit Output** span before its own acceptance is `[499728, 547776)` frames (`[10.411, 11.412) s`) at that active edit-map revision, not `[523728, 571776)`. If then accepted as Shorten, its history has a post-edit **seam** at Output frame `499728` and `No output position — removed by Shorten` for the omitted source frames; it does not claim that the removed frames occupy `[499728, 547776)`. If accepted as Lift instead, the reserved Output gap is `[499728, 547776)` with `No source inverse — Lift gap` inside. A changed clock map or earlier Shorten requires a newly computed position before that history entry can be called current. These are illustrative coordinates, not a claimed native implementation or a rounding rule for non-integral boundaries.

### 2.1 Safe default, alternatives, and refusal

1. `Shorten when safe` is the default only after the selected authorized Primary interval is fully timed/mapped in one occurrence/epoch and **every** affected lane has current backing, unambiguous coverage/inverse, protection proof, and a final fade footprint. The common rounded pre-edit output interval `[qStart, qEnd)` and rate `R` are shown before acceptance.
2. The user may change mode, boundary, or fades before accepting, but Adjust must keep the complete adjusted source-frame range **inside the original proposal** on the same selected Primary occurrence/epoch. Any change discards the old candidate proof and recomputes the common interval and every-lane result; it does not preserve an old duration, proof, preview, or render as if current. An out-of-proposal range is not an ordinary Adjust even if it is inside the same epoch and otherwise appears safe: it requires a **new, independently evidenced proposal with a separate person-confirmed action**, or a separately reviewed policy change; neither path is current Review behavior.
3. If protected frames intersect any removal or final merged fade footprint, both modes refuse that interval. Offer only separately shown/validated eligible **subintervals of that original proposal**, with fresh all-lane proof, or Manual review/Abstain; if none are eligible, there is no safe Adjust. For example, proposal Source `[480000, 528000)` in one Primary occurrence with protected `[484800, 489600)` may offer `[480000, 484800)` or `[489600, 528000)` only if each separately passes all-lane and fade checks. Source `[532800, 537600)` in the same epoch is **outside** the proposal and must be refused as Adjust even if otherwise unprotected; it is not a suggested escape from the overlap. No Force, Ignore Protection, or opt-in waiver exists.
4. `Lift - preserve timing` reserves exactly `qEnd - qStart` output frames on every affected lane. It is not an exception for unsupported backing, unknown protection, ambiguous inverse, missing word time, or stale data.
5. A candidate that is uncertain, stale, partially timed, unmapped, crosses an occurrence/epoch/gap, lacks a lane proof, has unknown silence, or cannot safely create a final fade state is Manual review/Adjust/Abstain. It is not auto-accepted and has no claimed complete preview.

### 2.2 Atomic invalidation and acceptance

Changing mode, source boundary, fade, source/backing, Primary, transcript, alignment map, protection, output rounding/rate, or active cut set invalidates the same all-lane map, timing preview, and render together. The interface changes `analysisState` to Stale or Pending and names the dependency; it must not leave a stale thumbnail, waveform, duration, or audio playable as current.

Accept publishes one named action only after a fresh person review action and all dependencies validate against the same revision. Publication updates the common map/history and invalidates preview/render atomically. A late result from an older revision cannot become visible as accepted or current. If atomic publication is not available, acceptance remains disabled with `Refusal: Common-map publication is unavailable`; there is no partial-lane success.

## 3. States, history, restore, and undo

The per-cut history names its target and retains prior actions. The policy's journal states are an input to this table, not proof that the app displays them today.

| State | Meaning and permitted next action | Required named history/announcement |
| --- | --- | --- |
| Pending | Candidate is inert and reviewable. | `Proposal <ID> pending`. |
| Adjusted | Current local request differs from the original candidate; it still needs a fresh all-lane proof before acceptance. | `Adjusted cut for <speaker> at <source range>`. |
| Accepted (active) | Current proof was accepted and is active in the common map. | `Shortened cut for <speaker> at <post-edit Output time, edit-map revision>` or `Lifted cut for <speaker> at <post-edit Output time, edit-map revision>`; preserve the distinct Source/Group/Aligned, pre-edit grid, and post-edit Output fields or explicit unavailable reasons. |
| Rejected | This revision creates no cut and remains inspectable. A future candidate is new, not silently revived. | `Rejected proposal <ID>`. |
| Restored (inactive) | The accepted cut is deactivated; boundaries/mode/fades/evidence remain in history. Preview may remain blocked if backing is unavailable. | `Restored cut for <speaker> at <source range>` with its historical post-edit Output position/revision labelled as historical, not current; show `No output position` if none can be mapped. |
| Abstained | Audio stays uncut; refusal/review reason is retained. | `Abstained from proposal <ID> — <reason>`. |
| Blocked or Stale | A dependency blocks activation or reactivation; no partial map change occurs. | `Could not <action> cut for <speaker> — <reason>`. |

`Restore` is available for an active accepted cut even if the source later becomes unavailable, because deactivation is nondestructive. `Undo Restore` is a reactivation attempt, not a guaranteed toggle: it revalidates source, Primary, transcript, map, protection, output recipe, other-cut, lane-manifest, backing, and final-fade proofs. A failed reactivation leaves the cut inactive and history intact, with a named refusal. Redo Restore deactivates again. Reject, Adjust, Accept, Restore, Abstain, Undo, and Redo never mutate original sources.

## 4. Keyboard, first responder, and text entry

The Review destination must use AppKit-compatible first-responder behavior, not a gesture-only or SwiftUI-focus-only path. Focus is visibly drawn around the logical control or row; selection state is separately exposed and is not communicated by color alone.

| First responder / focus group | Keyboard-only behavior | Return / Esc | Text-entry protection |
| --- | --- | --- | --- |
| Episode/sidebar and proposal list | Arrow keys move rows; Space does not accept; Tab/Shift-Tab move focus group. | Return selects/opens the inspector for the focused row; Esc clears a transient selection only when the standard control behavior does so. | N/A. |
| Timeline and numeric-list alternative | Arrows move the current item; the list exposes the same range/status as the timeline; pointer dragging is additive. | Return selects current proposal; Esc cancels an active pointer adjustment or sheet, never accepts. | N/A. |
| Inspector action button/radio group | Tab reaches every action, mode, boundary, and fade control; arrows select radio choices. | Return activates the focused enabled button only. Esc cancels an adjustment sheet/popover and restores its uncommitted values. | N/A. |
| Boundary/fade text field | Standard text editing, selection, copy/paste, and numeric validation; no implicit nudge while typing. | Return commits only the field's valid draft/recomputes proof; Esc restores the pre-edit field value. Neither accepts the cut. | All Review shortcuts yield to the field. |
| Transcript correction editor | Standard text editing; the caret/value remain owned by the editor. | Return and Space retain editor meaning; Esc follows the editor/sheet's standard cancellation behavior. | No playback, accept/reject, restore, delete, or timeline shortcut may consume Space or Return. |
| Labelled transport/menu command | Play/Stop/Audition uses an explicit focusable transport or menu item. Stop is separately reachable. | Return acts only when the transport is focused. Esc is never the only Stop command. | Invoking transport preserves editor text and caret. |

`Cmd+Z`/`Cmd+Shift+Z` use the standard Edit menu and announce the full named per-cut action. Proposed single-key shortcuts for Accept, Reject, mode selection, nudging, or audition are prohibited while any text editor/field is first responder. Context menus may duplicate commands but cannot be the only discovery route.

## 5. Accessibility and minimum-window requirements

Each changed control exposes its actual native role, unique label, value, enabled state, help/refusal, and stable `ww.review.<logical-id>.<element>` identifier. Label and value must state the same current status visible on screen; AX must not report a stale ready/default state after invalidation.

| Element | Role, label, value, and hit region contract |
| --- | --- |
| Proposal row | List row/table row; label includes speaker, source/occurrence, visible mode/state; value includes exact time availability and protection/stale qualifier. Entire visible row is the hit region. |
| Mode chooser | Radio group `Edit mode`; radio labels `Shorten` and `Lift - preserve timing`; selected value plus disabled/refusal reason. Each labelled radio has its own reachable hit region. |
| Numeric boundaries/fades | Text field or stepper with `Start source frame`, `End source frame`, `Fade out output frames`, `Fade in output frames`; value includes integer and unit/rate. Labelled increment controls are independently reachable. |
| All-lane proof/refusal | Group/list headed `All-lane safety`; each row labels lane identity and status. A blocked action's value/help names the exact lane and reason, not merely “Unavailable.” |
| Actions and history | Native button/menu item labels include action and target. Disabled actions remain discoverable, announce their reason, and do not expose an inactive hit region as enabled. |
| Preview status | Status/live region labels map revision, complete versus single-lane scope, and stale reason. It never calls a subset a complete preview. |

At the minimum supported Review-window size, and at 100% and 200% text in Light and Dark appearances, `analysisState`, `defaultMode`, refusal/recovery text, currently focused control, and one reachable safe action or explicit no-safe-action state must be readable without clipping, overlap, or an unreachable off-screen hit target. The inspector may scroll, but its scroll viewport and the refusal/recovery row must stay in the AX parent/child hierarchy and be reachable by keyboard. Reflow/scrolling is required; reducing text, relying on truncation/tooltips, or color-only badges is not a pass.

The physical-Mini contrast and AX containment defects in [#329](https://github.com/brandonmartinez/WaveWrangler/issues/329) remain unwaived. VM or package-only evidence can supplement functional work but cannot waive the required physical-Mini diagnostic/correction process, a native changed-surface AX audit, or the final 100%/200% checkpoint.

## 6. Data-dependency gates

The controls disclose, rather than hide, these gates:

| Gate | Required before Accept / reactivation / claimed complete preview | On failure |
| --- | --- | --- |
| Person action | One current, proposal-bound native person review action. | Refuse; no generated proposal can mint consent. |
| Selected Primary + word timing | Authorized selected Primary; explicit supported boundary frames in one occurrence/epoch. | Manual review/Adjust/Abstain; no guessed word time. |
| Complete lane manifest | Current trusted every-lane manifest, including Backup/other-speaker and explicit intentional-silence lanes. | Refuse and name missing/uninspectable lane. |
| Backing, inverse, coverage | Current backing, unique source inverse, continuous coverage, identity/channel/epoch, and endpoint error at most one output sample per audio lane. | Refuse; do not call an unknown lane silent. |
| Protection + fades | Current independently verified protection and final merged fade footprints for every lane. | Refuse both Shorten and Lift for protected/unknown frames; never waive. |
| Map/output recipe | Same current alignment, common rounded `[qStart, qEnd)`, rate, rounding/padding policy, active-cut set, and edit-map revision. | Invalidate preview/render; re-evaluate rather than reuse. |
| Source/offline authority | Approved local backing/media only; no implicit download, cloud/hosted fallback, source mutation, or backup analysis. | Block with existing safe Setup/Alignment remedy, or say no safe action. |

## 7. Executable/manual acceptance matrix

All rows are **Not run** for this documentation-only PR. “Pass” requires the listed evidence on the exact revision, not an assertion that a control was designed. A failure blocker remains a blocker until corrected and independently reviewed.

| ID | Owner | Executable/manual scenario | Intended evidence | Failure blocker |
| --- | --- | --- | --- | --- |
| PC-01 | Mac | At 100%, keyboard-select a Ready proposal, inspect `analysisState`/`defaultMode`, Shorten and Return only from the focused enabled Accept button; Esc cancels an uncommitted adjustment. | Exact-head native UI test plus AX tree/audit result: visible focus, roles/labels/values, hit regions, action audit. | No native per-cut first responder, ambiguous action, or a Return/Esc mismatch. |
| PC-02 | Pipeline + Alignment | On a synthetic every-lane fixture, Shorten only after current complete proof; verify one rounded common duration and no independent lane ripple. | Pure-state/renderer integration test with map revision, all lanes, endpoints, output rate, and expected history. | Missing lane, stale proof, wrong common duration, source mutation, or subset called complete. |
| PC-03 | Mac + Pipeline | Choose Lift on a protected-overlap fixture and use keyboard numeric Adjust only within separately validated subintervals of the original proposal; attempt a safe-looking out-of-proposal range in the same epoch and a protection waiver. | Native UI/AX test plus policy/integration refusal record naming lane/reason and out-of-proposal refusal. | Lift removes/attenuates protected frame, outside-proposal Adjust is offered/accepted, Force/waiver is exposed, or disabled reason is absent. |
| PC-04 | Mac + Alignment | Edit Start/End/fades by keyboard, then change mode/boundary/fade and attempt preview/render before recomputation completes. | Native/UI and integration test proving one atomic stale map/preview/render state and no late old-revision publish. | Old preview/render stays current, partial lane publication, or hidden stale reason. |
| PC-05 | Mac + Pipeline | Accept, Reject, Restore, Undo Restore with stale backing/protection, and Redo Restore. | Named Undo/Redo menu assertions, history records, and refusal evidence; sources remain unchanged. | Generic/incorrect target name, unsafe reactivation, lost history, or partial map change. |
| PC-06 | Mac | With transcript/boundary text entry focused, type Space/Return and invoke explicit audition/Stop. | Native UI test and AX evidence that value/caret persist and transport is labelled/reachable. | Custom shortcut changes text/caret, accepts a cut, or Stop depends on Escape. |
| PC-07 | Mac + Design | At minimum window, 100% and 200% text, Light and Dark, traverse blocked source/offline/protection state to remedy or no-safe-action. Run on physical Mini when #329 process reaches its diagnostic/correction stage. | Time-bounded manual checkpoint with SHA/host/appearance/text size/tasks, plus changed-surface AX/contrast audits. | Clipped/unreachable `analysisState`/`defaultMode`/refusal, failed contrast/AX containment, or #329 defect treated as waived. |
| PC-08 | Alignment + Pipeline + Mac | Exercise unavailable word time, stale map, ambiguous inverse, unknown backing/protection, explicit timed silence, and an earlier accepted Shorten plus clock correction. | Synthetic integration cases with distinct Source/Group/Aligned, pre-edit grid and post-edit Output values/revisions, `No source inverse`/`No output position`/`Unknown` states, and no fabricated frame/time value. | Generic unavailable state, stale or pre-edit grid shown as current Output time, guessed time/silence, implicit download/analysis, or acceptance of uncertain input. |

## 8. Freeze and review plan

Before a native implementation claims this contract, Pipeline, Alignment, and Mac independently review the mode/fade/protection, coordinate/common-map, and first-responder/AX bindings respectively. Their agreement does not itself pass the matrix.

For executable evidence, freeze the synthetic fixture identities, lane manifest, source/map/protection/output-recipe revisions, expected history, exact common endpoints/rate, and expected refusal labels before the run. Record exact SHA, host/OS, command or manual steps, test/audit identifiers, pass/fail/not-run/blocker outcome, and retained result location. Do not place media paths, transcript text, or other sensitive content in Git or review records. Offline/local approved-media, protection/source backing, and physical-Mini #329 work remain open; no package-only pass, policy test, or this document closes them.

**Independent design/domain review and coordinator acceptance remain pending.**
