# M3 transcript and edit review

**Owner:** Design · **Status:** proposed M3 interaction contract; documentary only, not implemented or validated.

**Refs:** [WW-025 (#22)](https://github.com/brandonmartinez/WaveWrangler/issues/22) · [WW-044 (#48)](https://github.com/brandonmartinez/WaveWrangler/issues/48) · [WW-029 (#26)](https://github.com/brandonmartinez/WaveWrangler/issues/26) · [M2 alignment inspection](../../m2/design/alignment-inspection-spec.md) · [M3 kickoff](../../planning/kickoffs/m3.md)

This specification extends the M1/M2 review conventions; it does not supersede their source immutability, state honesty, map-coordinate, keyboard, undo, or accessibility contracts. Its words are proposed UI copy and acceptance criteria, not evidence that a native surface or workflow exists. Pipeline, Alignment, and Mac must review the protected-edit, timing, and native feasibility details before implementation is treated as accepted.

## 1. Scope and invariants

The Review destination lets a person inspect a local transcript and conservative edit proposals for the episode's explicitly selected, authorized primary source/channel for each speaker. It does not transcribe or cue backups for speech review, promote a backup automatically, apply a suggestion on analysis, modify an original, export cleaned media, or establish speech-recognition accuracy beyond recorded evidence. M3 is not M4 cleanup/DAW handoff or M5 broad accessibility qualification.

1. **Primary is explicit.** M1 permits at most one Primary source/channel per speaker and any number of Backups. Show that role, the selected source/channel, and its availability separately. A Backup remains a Backup even if the Primary is missing, offline, denied, stale, or has no timing. Never silently substitute it. Changing a role does not itself authorize speech analysis: analyze only a track within the separately approved M3 set. Review must not provide a control that grants recording consent.
2. **Suggestions are inert.** Recognition and proposal generation never apply a cut. A transcript word, filler classification, timing, protection span, or edit mode is never described as confirmed until the relevant evidence/state exists and the person accepts the specific edit.
3. **Evidence is not probability.** Use only engine-produced status and evidence with its own units. Do not invent confidence percentages, probabilities, or accuracy labels. An unavailable timestamp stays unavailable; do not infer it from neighboring words, a waveform peak, another track, a backup, or an alignment gap.
4. **One map, immutable sources.** Source frames and the accepted edit map are authoritative. Preview and rendering consume the same revision and mapping. All edits are nondestructive project decisions; source files are read-only. A changed source, primary, transcript, or alignment map makes dependents stale and prevents publication until refreshed or explicitly reviewed.
5. **Protection cannot be overridden.** A protected speech frame is not deletable or attenuable by a cut, fade, lift, or boundary adjustment. No "force", "ignore protection", or equivalent override exists. If a safe edit cannot be represented, block it and offer review, adjustment outside the protected span, or abstention.
6. **Accessible alternatives are complete.** Every task has a keyboard/menu/AX path, visible focus, labelled state and remedy, and a non-drag numeric or list alternative. Color and waveform shape alone never communicate meaning.

## 2. Workspace and linked review context

Use the existing show window's Review destination (`Cmd+3`), keeping the episode sidebar and inspector conventions. Do not add a second review window or a modal-first workflow. The main area has three linked regions: a selectable transcript occurrence list, a timeline with speaker/source lanes, and the selection-driven inspector. The exact split and columns may adapt to the available width; they must remain navigable and must not hide a control or state.

The following logical context is the single selection model shared by all three regions:

| Field | Meaning |
| --- | --- |
| Episode, speaker, source, channel, recorder group, epoch | The exact review scope and origin of the displayed material |
| Occurrence ID | One source occurrence/span; not a file name or a display timestamp |
| Token ID(s) and caret | Selected transcript token(s), plus the insertion/caret position when text entry owns focus |
| Proposal/cut ID | The exact proposed or accepted edit under inspection, if any |
| Source-frame range | Exact half-open `[start, end)` boundaries in the source sample rate |
| Transcript revision and alignment-map revision | The versions that produced the visible text and timing |
| Focus owner | Transcript list, timeline/list alternative, inspector control, or text-entry field |

Changing a token selection selects its occurrence and updates the inspector and timeline highlight/playhead without discarding text, changing the caret, or stealing focus from a text-entry field. Changing the selected occurrence preserves the token/caret if it still belongs to that occurrence; otherwise it clears the token selection and reports the new occurrence. Selecting a proposal selects its exact boundary and explains its evidence and protected overlaps. Scrolling or moving the playhead alone does not change the transcript selection. An unavailable/stale selection remains selected so its reason can be read and remedied.

The inspector reports the full source/occurrence identity using stable logical IDs in accessibility identifiers; a display name may be shown as descriptive text but is not identity. If the panes cannot agree on source, occurrence, transcript revision, or map revision, show a blocked stale state instead of attempting a best-effort match.

## 3. Primary, backup, timing, and blocked states

Only observed states are presented. "Checking..." is used while a check is in flight; "Unknown" includes the reason when the check ends without an answer. A reason names the failing layer and the next safe action. Disabled actions remain discoverable and expose that reason in the visible inspector and AX help/value.

| Condition | User-facing state | Required behavior and remedy |
| --- | --- | --- |
| Selected and authorized Primary is available | "Primary - ready" | May be analyzed locally. Display speaker, source, channel, and current transcript/map revision. |
| Another source/channel is designated Backup | "Backup - not analyzed" | Show it in the speaker's source list and inspector. No transcript, timing, proposal, or automatic promotion is produced for it. |
| No Primary is selected | "No primary selected" | No analysis or cut action. Remedy: choose a Primary in Setup, then return to Review. |
| Primary is outside the approved speech-analysis set | "Speech analysis not authorized for this source" | No analysis or transcript exposure. No in-app confirmation changes this state; authorization must be established outside this Review action. |
| Source is missing or its location is unavailable | "Source not found" / "Source location unavailable" | Keep prior result marked stale if one exists; do not analyze or audition. Remedy through the existing Setup relink/source-availability flow. |
| Source permission is denied or needs renewal | "Access denied" / "Permission needs attention" | Do not retry through another path or use a backup. Remedy through Setup's existing permission flow. |
| Source is cloud-only, transfer pending, or download state is unknown | Exact existing source/transfer state | Do not initiate an implicit download. Show existing Setup remedy and its explicit action; analysis remains blocked until locally readable. |
| Local speech engine/model is unavailable | "Local speech engine unavailable" | No hosted or network fallback. Explain observed cause (not installed, incompatible, or unavailable) and point to the documented local setup remedy; if that remedy is not available, remain blocked. |
| Transcript has no word timing | "Timing unavailable" | Text may be inspected as transcript-only content, but no timeline placement, timing-dependent cut, or audition-to-word action is offered. Remedy: rerun supported local analysis or abstain. Never fabricate a timestamp. |
| Timing coverage is partial | "Timing incomplete - <n> of <total> words timed" | Timed and untimed words are distinct in text and list. Only an entirely timed, valid boundary range can become an edit proposal. Report counts, not a synthesized score. |
| Timing is outside mapped coverage | "Outside mapped range" | Do not extrapolate the M2 map. Show source time only and the existing timing remedy (inspect map / set timing in Alignment). |
| Timing falls in a clock gap or unsupported epoch | "Timing unavailable - <observed gap/unsupported reason>" | Do not bridge epochs or guess a position. Keep source-frame context, block linked timeline placement and edits, and link to Alignment. |
| Source identity/content changed since analysis | "Transcript stale - source changed" | Preserve the old result for inspection with a stale label; disable accept, adjust, audition-to-cut, and restore until reanalysis/review. |
| Selected Primary changed since analysis | "Transcript stale - Primary changed" | Never reuse another source's transcript. Disable edit actions; analyze the newly selected, authorized Primary to create a new revision. |
| Alignment map changed since analysis | "Timing stale - alignment changed" | Do not translate old times through the new map. Preserve source-frame details; refresh timing or return to Alignment. |
| Transcript/model revision changed | "Transcript stale - analysis changed" | Preserve old proposal history, mark derived suggestions stale, and require review of the current result. |
| Proposed boundary intersects protected speech or crosses an occurrence/epoch/gap | "Cut blocked - protected or unsupported audio" | State the exact cause and source-frame range. Offer safe lift/adjust/review/abstain only where valid; never expose a protection override. |
| Preview/render revision differs from accepted review revision | "Preview is out of date" | Stop publication of that preview/render; rebuild from the current common map. Never present stale audio as the current edit. |

The plain-language state is authoritative. Do not collapse missing, stale, unsupported, denied, offline, and not-authorized into one generic "unavailable" state. A state with no safe remedy says so explicitly rather than offering an action that cannot work.

## 4. Transcript and timing presentation

The transcript list is occurrence-scoped and ordered by source time, then stable token order. It distinguishes recognized words, non-speech events, unrecognized spans, and words without timing. Do not silently normalize uncertain text into a confirmed word. Where an engine provides a documented label or native evidence measurement, expose the label/measurement with its units and engine revision in Details; do not convert it to a probability.

Every timed token or segment can expose:

- source time and exact source-frame bounds;
- aligned time only when the current M2 map maps the whole occurrence range;
- speaker, selected Primary source/channel, epoch and occurrence;
- transcript/model revision, timing availability and any stale/blocked reason.

Display units explicitly. The time-map labels and sign conventions remain those in the M2 alignment specification. A gap or out-of-coverage range has no aligned timestamp. An untimed word has no timeline pin and cannot be used to infer an adjacent cut boundary. The numeric/list alternative exposes the same frame/time values and statuses as the graphical timeline.

Filler or other removal candidates are proposals, not a transcript filter or blanket "delete fillers" action. Each proposal identifies the exact source-frame interval, affected token IDs, reason/evidence basis, timing status, protection result, default edit mode, and any limitation. If the candidate is ambiguous, mistimed, stale, partly untimed, or intersects protected speech, the result is review/adjust/abstain, not auto-accept.

Transcript wording may be corrected by an explicit edit action in the selected token's inspector. The correction changes transcript revision only; it does not cut, move, or re-time audio. Commit is one named undoable action, preserves the current occurrence and caret/focus where possible, and invalidates proposals that depend on the changed token. If a correction splits/merges tokens or otherwise makes their original timing ambiguous, mark that timing unavailable until a new supported timing result exists. Text edits never clear an existing protection range; newly observed protection may add a block and requires proposal review.

## 5. Per-cut interaction and edit semantics

Each cut is independently reviewable and versioned. The list and timeline show Pending, Accepted, Rejected, Adjusted, Restored, Stale, or Blocked in text plus a distinct symbol. A proposal begins Pending; no cut is active merely because analysis completed.

### 5.1 Review actions

| Action | Effect |
| --- | --- |
| Accept | Accepts this proposal with the displayed default mode only after all timing, source, map, and protection checks pass. Acceptance is a single named undoable action. |
| Reject | Records that this exact proposal was rejected; it creates no cut and does not discard the transcript. A newly generated proposal is a new revision, not a resurrection of the rejected one. |
| Adjust | Opens the inspector's numeric boundary and mode controls. The person can choose a valid source-frame range and mode; edits cannot escape the occurrence/epoch or cross protected frames. |
| Restore | Reverses this accepted cut as a new, named, undoable action. It restores the exact previously accepted boundaries, mode, and fades to the common map after current safety/staleness checks. It does not overwrite source audio or erase history. |
| Abstain | Leaves the audio uncut and marks the reason the proposal cannot safely be accepted. It is not an error and does not require a guessed replacement boundary. |
| Undo / Redo | Uses the show's standard undo manager. Each accept, reject, boundary/mode/fade adjustment, restore, or abstention is one named action. Undo reverses that one decision and its stale-dependency effects together. |

The command title identifies both action and target, for example "Undo Shorten Cut for Speaker A at 00:12.340" or "Undo Restore Cut for Speaker A at 00:12.340". Do not use generic "Undo Edit" when multiple cuts exist. Redo names the same target. A proposal rejection is undoable and can be inspected in history.

### 5.2 Default shorten and timing-preserving lift

The default is **Shorten when safe**. For a valid accepted `[start, end)` source-frame interval, Shorten omits those frames and closes the resulting gap: later material moves earlier by the omitted duration on the output timeline. It is permitted only if no protected frame is removed, the interval is fully timed/mapped, and the edit stays within one source occurrence and epoch. The person may change the mode before accepting; the UI must not imply that Shorten is universally safe.

**Lift - preserve timing** is the explicit alternative for an editable cut that must not move later material. Lift omits only the accepted, unprotected frames but reserves an equal-duration empty output interval at that position, so material after the interval retains its pre-cut output time. If a proposal overlaps protection, eligible intervals may be split around protected frames; those protected frames remain present, untouched, and outside fade ranges. The inspector shows every resulting source-frame interval and the retained protected interval before acceptance. This definition is specific to WaveWrangler; it must not be left to an assumed DAW meaning.

No action can lift, shorten, fade, or trim a protected frame. If a proposal contains no removable frames after protected ranges are excluded, acceptance is blocked and the person can adjust outside the protection, review the transcript, or abstain. Protection is not an advisory tint or a preference.

### 5.3 Boundaries, fades, map, and preview

Boundary fields are exact integer source frames with the source sample-rate unit visible. The non-drag editor is mandatory; nudging is by one source frame, with a labelled larger increment. Validation requires `start < end`, a range inside the selected occurrence and epoch, complete current timing/map support, and no protected frames. Pointer handles, if implemented, must use the same checks and never be the only path.

Each cut has independent, explicit fade-out and fade-in lengths in labelled output frames; both default to zero. Fade-out ramps the retained audio before the cut boundary from its normal level to silence; fade-in ramps retained audio after the boundary from silence to its normal level. For Lift, the ramps border the reserved gap. A fade may affect only unprotected retained audio adjacent to the cut, must fit within that retained interval, and cannot overlap another fade or cross a protected range, occurrence, epoch, or map gap. Invalid lengths are refused with their reason, not silently clipped. Pipeline must confirm the exact envelope/curve and renderer semantics before implementation; preview and render must use the same frozen curve and lengths or the fade control remains unavailable.

All accepted cuts feed one ordered, revisioned common edit map. The map is applied to the complete episode preview and eventual internal render for every currently selected, authorized Primary source/channel, not only the selected transcript row or a short audition excerpt. Backup sources are never cued as part of this speech-review preview. Shorten changes later output positions; Lift preserves them with an explicit empty interval. Preview and render must agree on source-frame boundaries, map revision, fades, channel identity, and output timing. If any selected lane is stale, blocked, or inconsistent, the common preview is blocked or clearly limited; never silently preview a subset as if it were the whole episode. This is an internal review preview, not a mix/master, export, or M4 audio handoff.

The full common preview traverses the episode from beginning to end through that common map for all selected authorized Primary lanes. A bounded audition around the selected occurrence is an additional review aid and cannot replace full-preview acceptance. Both are read-only with respect to source files. The controls provide a visible, labelled Play/Stop transport, numeric/list position and range, and a clear current mode/status; stop is always reachable without dragging.

Changing a source, selected Primary, transcript, boundary, protection range, or alignment map invalidates the applicable derived preview/timing. Show the exact observed stale reason and affected edits/jobs. No stale preview or output can be accepted as current.

## 6. Essential keyboard, AX, VoiceOver, and text entry

The focus and VoiceOver reading order is episode sidebar, transcript occurrence list, timeline/list alternative, then inspector, matching the existing show-window focus-group pattern. Within each group arrows move among rows/items; Tab moves between groups and controls; focus remains visible. Review commands are also available in the menu bar. Context menus and pointer gestures are additive only.

- Every row/action/state has a stable `ww.review.*` accessibility identifier keyed by logical IDs, a native role, a unique human-readable label, a value containing the exact visible state plus necessary non-visible qualifiers, and an action hint only where needed.
- A selected transcript token announces its text, speaker, time availability, occurrence, and stale/protection state. Untimed or unmapped content is read as such, not as a blank or zero timestamp.
- The linked-selection contract in Section 2 applies under keyboard and VoiceOver navigation. Moving focus to a pane does not silently change the selection or caret in another pane. After a sheet closes, focus returns to the invoking row/control and the same occurrence remains selected.
- No custom shortcut consumes ordinary text-entry keys. While a text field/editor owns focus, Space and Return retain their text-editing meaning; no play/stop, accept, reject, delete, or timeline action is triggered by them. Audition is reachable through the visible labelled transport or Episode menu while preserving the editor's value and caret. Stop is always available from the transport/menu; Escape cancels a sheet or follows the standard focused-control behavior and is not the only stop path.
- Numeric boundary and range entry is available without dragging. List alternatives expose occurrence, exact frame/time, map state, cut mode, protection, and action availability in the same order and with the same values as the timeline.
- Blocked/recovery states remain in reading order with a plain reason and reachable remedy. Essential text wraps; no status depends on color, animation, waveform geometry, or sound alone.
- Run the per-PR essential audit on changed surfaces: keyboard-only core paths with visible focus and Return/Esc behavior; AX role/label/value and `elementDetection`, `sufficientElementDescription`, `hitRegion`, and `action` audits; `.contrast` for blocked/recovery surfaces; reachable remedies; no color-only or drag-only task. A manual VoiceOver listening/participant study, Full Keyboard Access system qualification, broad contrast/reduced-motion/reference-device review, and M5 qualification are not evidenced by this design document.

## 7. Deferred and unresolved implementation contracts

This document does not choose a recognizer, prescribe a protected-speech classifier, infer accuracy, define renderer DSP, or claim native feasibility. Pipeline must confirm proposal/protection semantics and the no-network-fallback boundary; Alignment must confirm source/aligned/output-frame conversion and stale-map behavior; Mac must confirm AppKit/SwiftUI focus, text-entry preservation, accessibility tree, undo integration, and safe preview/render binding. Any disagreement that weakens a safety invariant must be raised to Lead with options; it must not be silently treated as approved.

The implementation must not use this proposal as authority to inspect a backup, another recording, or media outside the dated M3 consent. Evidence must remain aggregate-only and synthetic fixtures must cover automated tests, per the kickoff.
