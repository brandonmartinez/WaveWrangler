# M2 alignment inspection and manual-correction specification

**Owner:** Design · **Status:** specification for WW-022 implementation. **Not implemented or tested.** ·
**Refs:** [WW-014 (#14)](https://github.com/brandonmartinez/WaveWrangler/issues/14) (this spec) ·
[WW-022 (#17)](https://github.com/brandonmartinez/WaveWrangler/issues/17) (implementation) ·
[docs/m2/ww-019-m2-contracts.md](../ww-019-m2-contracts.md) (M2-C3 conventions, M2-C4 map states, drift
fallback) · [WWTimeMap `MapProvenance`/`GroupTimeMap`](../../../Packages/WaveWranglerKit/Sources/WWTimeMap) ·
[WWDecode `DecodeFailure`](../../../Packages/WaveWranglerKit/Sources/WWDecode/DecodeFailure.swift) ·
[docs/research/waveform-clock-render-readiness.md](../../research/waveform-clock-render-readiness.md).

Companion M1 documents (unchanged conventions this spec extends): [information architecture](../../m1/design/information-architecture.md) ·
[states and recovery](../../m1/design/states-and-recovery.md) · [commands and keyboard](../../m1/design/commands-keyboard.md) ·
[accessibility acceptance](../../m1/design/accessibility-acceptance.md).

## 1. Ground rule: evidence, not probability

Every map state shown to the user traces to a `MapProvenance` or `TimeMapRegionState` value Alignment's
engine actually produced (M2-C4). **No UI text may say or imply a probability, confidence percentage or
likelihood of correctness.** `AcousticConsistencyProposal.evidenceScore` and the measurement fields on
`ClockGateMeasurements`/`AcousticConsistencyMeasurements` are evidence numbers (residual milliseconds,
window counts, coverage fractions) and are shown **labelled with their own units**, never rescaled into a
percentage or a word like "likely"/"confident". `clockApproved` is reachable only once a
frozen-holdout-qualified WW-016 evaluator exists (M2-C4, contracts §6); until then every epoch that isn't
`manual` or `externalEvidence` is `acousticConsistentProposal` at best, and the UI must never word a
proposal as clock-approved.

### 1.1 Epoch map-state wording catalog

One row of the Anchors & Map list (§4) is one `RecordingEpochID` within one `EpochClockMap`. Columns:
engineering source, user-facing label, SF Symbol, meaning sentence (exact, used in the inspector and list
cell help), and the available actions. Symbol shapes follow M1's ST-02 families; no state is colour-only.

| ID | Engineering source | Label (list cell) | Symbol | Meaning (inspector / VoiceOver value) | Actions |
| --- | --- | --- | --- | --- | --- |
| **U1 Reference** | `MapProvenance.timelineReference` | "Reference" | `flag.checkered` | "This is the timeline's reference epoch. Every other epoch is measured against it." | — |
| **U2 Supported** | `MapProvenance.clockApproved` | "Supported" | `checkmark.seal` | "An independent clock reference confirms this epoch's timing. Evaluator: <name>. Residual: p95 <x> ms, max <y> ms over <n> windows." | Audition · View Measurements… |
| **U3 Weak (proposed)** | `MapProvenance.acousticConsistentProposal` | "Proposed — not confirmed" | `waveform.circle` | "WaveWrangler found this timing consistent with the audio content, but acoustic delay can look the same as a clock difference. This is a proposal, not a confirmed clock correction. Evidence: <estimator> residual p95 <x> ms over <n> windows, <coverage>% of the declared overlap." | Accept as Manual… · Reject · Edit Numerically… · Place Anchors… · Audition |
| **U4 Manual** | `MapProvenance.manual` | "Set by you" | `hand.point.up.braille` | "You set this timing yourself." + basis sentence: numeric entry → "You typed the rate and offset."; anchors → "Fitted from the anchors you placed."; accepted proposal → "You reviewed and accepted WaveWrangler's proposal." | Edit Numerically… · Place Anchors… · Audition · Revert to Proposal (only after `acceptedAcousticProposal`) |
| **U5 External evidence** | `MapProvenance.externalEvidence` | "External evidence" | `antenna.radiowaves.left.and.right` | "You supplied outside evidence for this timing: <kind sentence, e.g. shared timecode generator>. <description>." | Edit Numerically… · Audition |
| **U6 Gap** | `TimeMapRegionState.gap` / `ForwardMapping.gap` / `InverseMapping.gap` | "Gap — clock restarted" | `arrow.triangle.branch` | "The recording stopped and restarted here. WaveWrangler never bridges or guesses across a gap; the epoch on each side is timed separately." | Go to Epoch Before · Go to Epoch After |
| **U7 Disconnected** | `UnsupportedReason.disconnected` | "Disconnected — no timing evidence" | `bolt.slash` | "WaveWrangler found no usable timing evidence for this epoch (for example, an acoustic delay made the evidence unreliable, or there's no shared content). Set the timing yourself." | Edit Numerically… · Place Anchors… |
| **U8 Unsupported** | `UnsupportedReason.notAttempted` / `.estimatorAbstained` / `.insufficientOverlap` / `.nonlinear` / `.acousticOnly` | "Unsupported" + reason clause | `questionmark.circle` | Reason clause: notAttempted → "WaveWrangler hasn't attempted timing for this epoch yet."; estimatorAbstained → "WaveWrangler's estimator abstained — it couldn't produce a reliable result."; insufficientOverlap → "Not enough shared recording time to estimate timing."; nonlinear → "The drift isn't a simple constant rate, which WaveWrangler doesn't model."; acousticOnly → "Only acoustic evidence exists, below the threshold WaveWrangler uses for even a proposal." | Edit Numerically… · Place Anchors… |
| **U9 Outside coverage** | `outsideCoverage` | "Outside the mapped range" | `arrow.up.and.down.and.arrow.left.and.right` | "This instant is before the first or after the last mapped time for this occurrence. WaveWrangler never guesses beyond what it mapped." | Go to Nearest Mapped Time |

- A list row never shows a bare engineering enum name; the label and meaning sentence are the only wording
  (A-02-style wording-catalog test applies, §8).
- U2's sentence appears only while a holdout-qualified evaluator exists in the build; until then U2 is
  **unreachable in the UI** and its row is absent from any catalog/menu test fixture, not merely dimmed —
  because `ClockApproval` has no public construction path yet (`MapProvenance.swift` doc comment).
- `evidenceScore` (U3) is shown only as "Evidence score: <value>, <estimator>'s own scale" in the Details
  disclosure, never as a headline, never as "%", never with a word like "confidence".

### 1.2 Source blocked-state wording (decode failures feeding alignment)

An occurrence that can't be decoded has no acoustic evidence available at all; it is shown as a distinct
blocked row, not folded into U7/U8. Values map `DecodeFailure` (`DecodeFailure.swift`) to exact sentences,
following M1's honesty rule (ST-01: a state is shown only when observed).

`DecodeFailure` has **no advisory/non-blocking tier**: every case is a `throw` before any occurrence is
produced (`DecodeEnvelope.swift` throws `.unsupported(reason)` before a single frame is read), so there is
no "decoded, but timing might be off at the start" state. Every case below is fully blocking; the table
below maps each `DecodeFailure`/`UnsupportedReason` case to exactly one row.

| `DecodeFailure` case(s) | Label | Symbol | Sentence |
| --- | --- | --- | --- |
| `.unsupported(reason)` — every `UnsupportedReason`: `.container` / `.codec` / `.sampleFormat` / `.sampleRate` / `.channelCount` / `.encoderDelayUnknown` / `.unverifiableContainerLength` / `.variableFramesPerPacket` | "Can't read this file" | `xmark.octagon` | "WaveWrangler can't decode “<file>” for alignment: <plain reason from the case, e.g. 'unsupported sample rate' / 'can't verify this file's declared length'>." |
| `.unreadableContainer` / `.missingAudioData` / `.truncated` / `.incompleteContent` / `.inconsistentStream` / `.decodeFailed` — exactly `DecodeFailure.isContentDamage == true` | "Can't read this file" | `xmark.octagon` | "WaveWrangler started reading “<file>” but it looks damaged or incomplete, so it can't be used for alignment." |
| `.notFound` / `.permissionDenied` / `.notMaterialized` / `.residencyUnknown` | *(reuses the M1 source-state row that applies; see [states §3](../../m1/design/states-and-recovery.md#3-source-states-five-independent-dimensions))* | — | Alignment shows "Resolve this source's availability in Setup before it can be timed." with a **Go to Setup** button; it never duplicates the Setup remedy. |
| `.notARegularFile` / `.notOpenedReadOnly` / `.metadataUnavailable` / `.emptyFile` / `.readFailed` / `.sourceIdentityMismatch` / `.sourceChangedDuringDecode` / `.sinkFailed` / `.cancelled` | "Can't read this file" | `xmark.octagon` | "WaveWrangler couldn't read “<file>” for alignment (<brief reason, e.g. 'the file changed while reading' / 'an internal read error'>). Try again, or resolve it in Setup." |

A source row showing any "Can't read this file" state has every Alignment action (anchors, numeric entry,
audition for that occurrence) disabled, with the sentence as the disabled reason — never a silently
dimmed control (CMD-02).

## 2. Source / group / aligned time labels

Three coordinate labels appear throughout the Alignment UI, matching M2-C3 exactly (`source_frame / F +
epoch = group`; `aligned = a × group + b`). WW-015 is the only source of truth for these conventions; this
spec never redefines them.

| Label (exact UI text) | Meaning | Unit shown | Sign convention |
| --- | --- | --- | --- |
| **Source time** | `n / F` — the occurrence's own frame position, in its native sample rate | `h:mm:ss.mmm` (frame count in the Details disclosure) | Always increases; frame 0 is the start of the occurrence |
| **Group time** | `source_frame / F + epoch` — the recorder group's shared clock coordinate | `h:mm:ss.mmm` | Equal-origin convention (`docs/research/foundation-spikes.md`); never negative within a mapped epoch |
| **Aligned time** | `a × group + b` — the cross-group aligned coordinate used for inspection/playback | `h:mm:ss.mmm` | Same equal-origin convention; a target placed later by a positive lag has `b = −lag / F` |
| **Rate correction** | `map_ppm = 10⁶ × (a − 1)` | **ppm**, signed (`+`/`−`), 3 decimal places | Positive = this occurrence's recorder clock runs **slow** relative to the reference timeline: its `F` nominal frames span `a > 1` aligned seconds (actual rate `F/a`), so its content drifts later than naive `n/F` placement (`ClockConventions.swift`: "Positive ppm (a > 1) means the group's recorder clock runs SLOW relative to the reference timeline") |
| **Offset correction** | `b`, converted to time | **ms**, signed | Positive = this occurrence's audio is shifted later on the aligned timeline |

- Every numeric time field shows its exact value; WaveWrangler never rounds a displayed source/group/aligned
  time to a tick without exposing the precise value in the Details disclosure (mirrors M1 CMD-20's "no
  essential value is lost" rule).
- Units are never implicit: a lone number with no "ppm"/"ms"/timecode suffix is never shown.
- Gaps (U6) and outside-coverage (U9) regions show no aligned time at all — a blank with the state's label,
  never an extrapolated guess (`outsideCoverage` doc comment: "never extrapolated").

## 3. Window placement, menu commands and shortcuts

### 3.1 Where it lives

This spec adds exactly **one** content panel: the existing **Alignment** destination (`⌘2`,
`ww.show.destination.alignment`), which M1 left as a permanently blocked panel (IA §4.2). WW-022 replaces
that blocked panel's content with the Alignment workspace below when the show's current episode has at
least one recorder group; the blocked-panel wording still applies when no recorder group exists yet ("Set
up at least one recorder group in Setup first" replaces the M1 "later version" body — the heading, button
and `ww.show.blocked.alignment` identifier are otherwise unchanged). No new window, sheet-heavy flow, or
second workspace is introduced; the inspector (`⌃⌘I`) is reused for per-row detail, matching Setup's
pattern (IA §4.4).

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ◧  The Daily Wrangle — Edited      [ Setup | Alignment | Review | Export ]   ✎ Edited ▾      ⓘ   │
│    Interview with Ana                                                                            │
├────────────────┬──────────────────────────────────────────────────────────────┬──────────────────┤
│ EPISODES    +  │ Recorder Groups & Epochs                      [Audition ▸]   │ INSPECTOR        │
│  12 Interview… │  Group        Epoch  State              Rate      Offset     │ Epoch 1 · laptop │
│  11 Listener…  │  ▾ Zoom H6 (reference) · Epoch 1  ✓ Reference      —    —    │ State: Proposed  │
│  10 Live from… │  ▾ Ana's laptop                                             │ Evidence: p95 3.1│
│ SHOW           │     Epoch 1  ≈ Proposed — not confirmed  +12.040ppm +84.2ms │  ms, 7 windows,  │
│  Show Info     │     Epoch 2  ⚡ Gap — clock restarted      —        —       │  86% overlap     │
│                │     Epoch 3  ? Unsupported — estimator abstained            │ [Accept][Edit…]  │
│                │ Anchors (Epoch 1, Ana's laptop)                [+ Anchor]   │ [Place Anchors…] │
│                │  # Source time   Group time    Aligned time    Delete      │ [Audition]       │
│                │  1 0:00:12.040   0:00:12.040    0:00:12.084     [x]        │ Range[▸5s][■]    │
│                │ Dependents affected by accepting this map: 3 edits, 1 job will become stale    │
└────────────────┴──────────────────────────────────────────────────────────────┴──────────────────┘
```

*Illustrative mockup, not to scale.* The Recorder Groups & Epochs table and the Anchors table are each
their own focus group (Tab moves between them, matching Setup's Sources/Speakers split, IA §4.3).

### 3.2 Regions and accessibility identifiers

Extends IA §7's `ww.<window>.<region>.<element>[.<logicalID>]` pattern; row identifiers use logical IDs
(`groupID`, `epochID`, `anchorID`), never a file name.

| Identifier | Element |
| --- | --- |
| `ww.alignment.groups` / `ww.alignment.group.<groupID>` / `ww.alignment.epoch.<epochID>` | Recorder Groups & Epochs outline and rows |
| `ww.alignment.epoch.<epochID>.state` | State cell (U1–U9 label + symbol) |
| `ww.alignment.epoch.<epochID>.rate` / `.offset` | Rate (ppm) / offset (ms) cells |
| `ww.alignment.anchors` / `ww.alignment.anchor.<anchorID>` | Anchors table and rows (scoped to the selected epoch) |
| `ww.alignment.anchor.<anchorID>.sourceTime` / `.groupTime` / `.alignedTime` | Anchor time cells (editable) |
| `ww.alignment.audition` / `ww.alignment.audition.range` / `.play` | Audition control and transport |
| `ww.alignment.dependents` | Stale-dependents summary line (§4.5) |
| `ww.inspector.alignment.state` / `.evidence` / `.rate` / `.offset` / `.basis` | Inspector fields for the selected epoch |
| `ww.show.blocked.alignment` | Blocked panel (unchanged identifier; new body text when no recorder group exists) |

### 3.3 Menu commands and shortcuts

Added to the existing **Episode** and **Edit** menus and the WWOrganizer `MenuCommand` register
(`MenuCommands.swift`); no new top-level menu. Every item also has a toolbar/inspector/context-menu path
(CMD-01) and a dimmed-with-reason state when unavailable (CMD-02).

| Item | Menu | Shortcut | Enabled when | Notes |
| --- | --- | --- | --- | --- |
| Place Anchor at Playhead | Episode | — (no free custom slot; command-only, listed in Help › Keyboard Shortcuts) | An occurrence is selected in Alignment and audition is paused | Adds one `.manual(.anchors)` anchor at the current audition position in both the source and group tracks; "Undo Place Anchor" |
| Edit Epoch Timing Numerically… | Episode | — | An epoch row is selected | Opens the numeric rate/offset sheet (§4.2); "Undo Edit Epoch Timing" |
| Accept Proposal as Manual | Episode | — | Selected epoch is U3 (Proposed) | Converts to `.manual(.acceptedAcousticProposal)`; marks dependents stale (§4.5); "Undo Accept Proposal" |
| Reject Proposal | Episode | — | Selected epoch is U3 | Clears the proposal back to U8 (`notAttempted`); "Undo Reject Proposal" |
| Start New Epoch at Anchor | Episode | — | An anchor is selected | Splits the occurrence's placement into a new epoch at that frame (restart/gap semantics, M2-C3); "Undo Start New Epoch at Anchor" |
| Delete Anchor | Edit (via Delete, ⌫, when an anchor row is focused) | ⌫ | An anchor row is focused | Same confirmation pattern as M1 row deletion when ≥2 anchors would remain; refitting a manual map to <2 anchors instead reverts that epoch to U8 with an explanatory sentence |
| Audition Selection | Episode | ⌘⏎ (Return while an epoch/anchor row or audition range is focused) | A row with a defined aligned time is selected | Plays the selected region of that source or group only — an internal check, never an export (§4.4) |
| Stop Audition | Episode | Esc (while auditioning) | Audition playing | |

- The shortcut register test (A-06 style) must assert these additions introduce no duplicate key
  equivalent and that ⌘⏎/Esc read correctly while a table row (not a text field) has focus, per CMD-06.
- No pointer-only command exists: every row above also appears in the Episode menu, so Full Keyboard
  Access and VoiceOver users reach every action without the inspector buttons (CMD-01, CMD-07).

## 4. Interaction model

### 4.1 Anchor list

Anchors are per-epoch, per-occurrence pairs of (source time, their corresponding group/aligned time),
ordered by source time. The Anchors table (§3.1) always shows **Source time**, **Group time**, **Aligned
time** for the epoch selected in the Recorder Groups & Epochs table above it — never anchors from another
epoch, so a gap (U6) never silently mixes anchors across it (M2-C3: "a gap always starts a new epoch").

- **≥2 anchors** are required before a `.manual(.anchors)` map can be fitted; fewer than 2 leaves the epoch
  unsupported (U8, reason `notAttempted`) with the sentence "Add at least one more anchor to time this
  epoch."
- Placing, editing or deleting an anchor is a single undoable action each ("Undo Place Anchor", "Undo Edit
  Anchor Time", "Undo Delete Anchor"), named per M1's undo convention (commands-keyboard §3).
- Editing an anchor's aligned time is numeric-only (no drag): type the value, or ↑/↓ nudges by one output
  frame (shift-↑/↓ by 100 ms), matching M1's "no drag-only interaction" rule (IA §5).

> **Revision 2026-10-07 (WW-022, #219, Lead design decision).** A focused **Edit Anchor…** sheet replaces
> inline editing in the Anchors table. Inline "Aligned time" editors inside the clipped native table could
> not reliably take or hold keyboard focus, so the Anchors table is now selectable but **read-only**: the
> three time columns are `staticText` with their §5.2 labels and values. Return on the selected anchor row
> — or Episode › Edit Anchor… — opens the sheet with its labelled "Aligned time" field already focused;
> the ↑/↓ frame nudges above live in that field. After **Place Anchor at Playhead** is accepted the new
> anchor row is selected and the sheet opens on it. Return applies one undoable edit and Escape cancels;
> either way the sheet's dismissal returns keyboard focus to that anchor's row. The keyboard-only path,
> VoiceOver role/label/value, numeric entry and undo requirements of §4.1, §5.1 (T-M2-02, T-M2-03) and
> §5.2 are otherwise unchanged. **Start New Epoch at Anchor** is likewise enabled only when the selected
> anchor's frame lies strictly inside the selected occurrence's span; an endpoint selection is refused in
> the status line rather than silently, with the pipeline rejection kept as a backstop.
>
> The Alignment workspace root is labelled on the AppKit side, on the `NSHostingView`: declaring the
> SwiftUI root as a containing element absorbed the `ww.alignment.workspace` scroll area and its
> identifier out of the tree entirely. One accessibility finding remains waived — AppKit builds the
> container around each alignment outline cell itself, and no SwiftUI
> description reaches it (labelling the cell content, combining its children and the value-keypath
> shorthand were each tried). The waiver is gated on that container still exposing its own labelled
> text child, and is capped at one finding per cell. The row of alignment action buttons is a named
> container ("Alignment actions") rather than a waiver. Two further waivers cover chrome the app does not
> build: the show's split layout (two containers over the content area, plus the episode sidebar) and
> SwiftUI's inspector column around the labelled `ww.inspector` scroll area. Each is matched by the exact
> frame of a labelled element and capped. **These waivers need Lead sign-off.**

### 4.2 Numeric rate/offset correction

"Edit Epoch Timing Numerically…" opens a sheet with two fields: **Rate correction (ppm)** and **Offset
(ms)**, both signed numeric fields with steppers, labelled exactly as in §2's table. Return applies and
produces a `.manual(.numericEntry)` map; Esc cancels. The sheet previews the resulting first/last aligned
time for the epoch's occurrence so a typo is visible before committing. This sheet is the **required
non-drag path** for every correction a future pointer/graph affordance might offer (IA §5 pattern); WW-022
may add a draggable rate/offset control only once this sheet exists and remains fully equivalent.

### 4.3 Multiple clips, epochs and grouping

- A recorder group may have any number of epochs (restarts); each epoch's map state and anchors are
  independent (§1.1, §4.1). The Recorder Groups & Epochs table is a two-level outline — group row then
  epoch rows — mirroring Setup's Recorder Group → Source hierarchy (IA §4.3).
- An occurrence with more than one span in one group (recorded, stopped, restarted onto the **same**
  recorder without a declared new epoch) is impossible by construction (M2-C3: "a gap always starts a new
  epoch"; `gapMustRestartEpoch`); the UI never offers a control that would create that state.
- Grouping/epoch assignment itself (which sources share a group, which epoch a span belongs to) is edited
  in **Setup**, not here (Setup already owns Recorder Group/Epoch, IA §4.4); Alignment only *times* the
  epochs Setup defines and offers **Start New Epoch at Anchor** (§3.3) as the one Alignment-side way to
  split a placement when a discontinuity is discovered during inspection.

### 4.4 Audition

Audition plays back the selected **range** of one source or group track so the person can listen while
inspecting a map — strictly an internal review aid, never an export or a cut (out of scope §6). The
transport is a single Play/Stop toggle plus a numeric range (start/duration, not a draggable scrubber
alone): typing or ↑/↓-adjusting the range fields is the required non-drag path; a optional draggable
range handle may be added only with that numeric field as its always-available equivalent (IA §5). Audition
never writes a derived asset; it reads the existing aligned map and the source/group tracks read-only.

### 4.5 Undo/redo and staleness

- **Every** correction in this spec (place/edit/delete anchor, numeric entry, accept/reject proposal, start
  new epoch at anchor) is a single named undoable action sharing the episode's `UndoManager`, per M1's
  convention (commands-keyboard §3) — this list is the WW-022 addition to that table.
- **REF-019 (contracts §6): accepting a map change marks dependent work stale.** Accepting a proposal,
  committing a numeric/anchor correction, or starting a new epoch at an anchor immediately recomputes which
  downstream jobs (derived aligned assets, and in later milestones speech/edit/export work) are keyed to
  the old map revision (M2-C5 invalidation keys) and marks them stale. The Alignment panel always shows a
  live count at `ww.alignment.dependents`: "Dependents affected by accepting this map: <n> edits, <m> jobs
  will become stale" (zero is shown as "No dependent work yet," never hidden). Undo reverses the staleness
  exactly as it reverses the map edit — nothing here invents a separate "confirm staleness" dialog.

## 5. Essential accessibility

Per the Design charter's essential-accessibility gate: keyboard-only path with visible focus and
Return/Esc; AX role/label/value for every control and state; every blocked/error/recovery state reachable,
labelled and legible; no colour-only state; no drag-only interaction.

### 5.1 Keyboard-only path (focus order and K-flows)

Focus order within Alignment: Recorder Groups & Epochs table → Anchors table (scoped to the selected epoch
row) → inspector fields, matching Setup's table → table → inspector order (IA §4.1). Tab moves between the
three groups; arrows move within a table; Return opens/focuses the inspector's first editable field for
the selected row (consistent with M1's `Return` behaviour in Sources/Speakers tables, commands-keyboard
§4.2).

| ID | Task | Keyboard-only path |
| --- | --- | --- |
| **T-M2-01** | Open Alignment and read an epoch's state | ⌘2 → arrow to a group row → → to expand → arrow to an epoch row → state is read in the row and the inspector |
| **T-M2-02** | Place an anchor | Select an occurrence's track/epoch → Menu › Episode › Audition Selection (⌘⏎) → Esc or Stop at the desired instant → Menu › Episode › Place Anchor at Playhead → the new anchor row is selected and the Edit Anchor sheet opens with "Aligned time" focused (§4.1 revision) |
| **T-M2-03** | Edit an anchor's time numerically | Arrow to an anchor row → Return opens the Edit Anchor sheet with "Aligned time" focused → type a value → Return commits ("Undo Edit Anchor Time" available) and focus returns to the row (§4.1 revision) |
| **T-M2-04** | Delete an anchor | Arrow to an anchor row → ⌫ → confirmation if it would leave <2 anchors → Return confirms |
| **T-M2-05** | Correct an epoch numerically | Select an epoch row → Menu › Episode › Edit Epoch Timing Numerically… → Tab between Rate (ppm) and Offset (ms) → Return applies, Esc cancels |
| **T-M2-06** | Accept an acoustic-consistent proposal | Select a U3 epoch row → Menu › Episode › Accept Proposal as Manual → state becomes U4; dependents count updates and is announced |
| **T-M2-07** | Reject a proposal | Select a U3 epoch row → Menu › Episode › Reject Proposal → state becomes U8 |
| **T-M2-08** | Start a new epoch at a discontinuity | Select an anchor at the discontinuity → Menu › Episode › Start New Epoch at Anchor → the placement splits; the new epoch row is focused |
| **T-M2-09** | Audition a region | Select an epoch or anchor range → Menu › Episode › Audition Selection (⌘⏎) → Esc or Menu › Episode › Stop Audition stops |
| **T-M2-10** | Reach a blocked/gap/unsupported state and its remedy | Arrow to a U6/U7/U8 row → the state and meaning sentence are read → Tab to the row's listed action button (e.g. "Place Anchors…") |
| **T-M2-11** | Confirm a stale-dependents notice | After T-M2-06/T-M2-08, arrow to `ww.alignment.dependents` → the updated count is read without moving focus away from the table |
| **T-M2-12** | Recorder group has no epochs yet (blocked panel) | ⌘2 with no recorder group in Setup → blocked panel heading/body is read → Tab to **Go to Setup** → Space |

### 5.2 AX role, label and value per control

| Control | Role | Label | Value |
| --- | --- | --- | --- |
| Epoch row | `row` (outline) | "<Epoch n>, <Recorder Group>" | State label from §1.1 (e.g. "Proposed — not confirmed") |
| State cell | folded into the row's value (ST-03 pattern: no separate AX element for the symbol) | — | Full meaning sentence from §1.1 |
| Rate / Offset cell | `staticText` | "Rate correction" / "Offset" | "+12.040 ppm" / "+84.2 ms", or "—" (VO "none") when unmapped |
| Anchor row cells | `staticText` (read-only since the §4.1 revision; the editable field lives in the Edit Anchor sheet) | "Source time" / "Group time" / "Aligned time" | Exact timecode string |
| Audition transport | `button` | "Play" / "Stop" (title reflects state, CMD-05 pattern) | — |
| Audition range fields | `textField` | "Start" / "Duration" | Exact timecode |
| Dependents line | `staticText` | "Dependents" | "<n> edits, <m> jobs will become stale" / "No dependent work yet" |
| Accept/Reject/Place Anchor/Start New Epoch buttons | `button` | Exact menu-item title | Disabled state carries its reason in the AX `help` (mirrors CMD-02) |

Announcements (extends M1 states §7): accepting/rejecting a proposal announces "Accepted proposal for
Epoch <n>" / "Rejected proposal for Epoch <n>"; the dependents count changing announces "<n> edits, <m>
jobs now stale" once per change, at low priority (mirrors the M1 "3 sources need attention" pattern).
`XCUIApplication.performAccessibilityAudit(for:)` with `.elementDetection, .sufficientElementDescription,
.hitRegion, .action` runs at the end of every new Alignment surface (accessibility-acceptance §4.2), scoped
to the changed surfaces only (charter: "essential before broad" — per-PR audit is limited to these four
types). `.contrast` runs only on the blocked panel (§3.1, `ww.show.blocked.alignment`) and any error/recovery
sheets (e.g. a failed Accept/Place Anchors attempt); broad `.contrast` across every Alignment surface is
M5/WW-053, out of scope here.

### 5.3 No drag, no colour

| Optional drag/colour affordance | Required non-drag / non-colour alternative |
| --- | --- |
| Dragging a waveform region to set an anchor | Audition Selection + Place Anchor at Playhead (T-M2-02); numeric anchor time fields (T-M2-03) |
| Dragging a rate/offset graph handle | Edit Epoch Timing Numerically… sheet (§4.2), which exists before any graph affordance ships |
| Dragging the audition range | Numeric Start/Duration fields (§4.4) |
| State shown only by tint | Every state in §1.1/§1.2 has a distinct symbol shape and label text (ST-02 families reused: `checkmark`=fine, `waveform`/`hand`=proposal/manual distinct shapes, `questionmark`=unsupported, `arrow.triangle.branch`=gap, `xmark.octagon`=failed) |

### 5.4 Design-for rules (so M5 doesn't force rework)

- **Semantic fonts and colours:** state symbols and all text use system text styles and semantic colours
  (`.secondary`, `systemOrange`, `systemRed` per M1's tint table, states §1); no custom hex colour is
  introduced for Alignment states.
- **Reflowable containers:** the Anchors table and the inspector's evidence text use natural text
  containers that wrap (no fixed-height text box), so 200% text (M5, out of scope for M2 itself) does not
  require later restructuring.
- **Constant column ideal widths:** the Recorder Groups & Epochs and Anchors tables never add or remove
  columns on resize; columns (State, Rate, Offset / Source time, Group time, Aligned time) keep constant
  ideal widths and use `TableColumnCustomization` visibility toggles if hidden, matching the Setup table's
  pattern (`EpisodeSetupView.swift` `SourcesTable`, `.squad` memory "SwiftUI tables").

## 6. M2 window smoke-pass checklist

Run once the Alignment panel first renders real data (charter: "window smoke pass… as each new window
lands"). Essential checks plus zoom/resize only — not a full visual matrix.

| # | Check |
| --- | --- |
| 1 | Window resizes from its minimum to full-screen without a clipped essential value (state label, ppm/ms numbers, timecodes) |
| 2 | Zoom (green button) restores the previous frame; no layout break |
| 3 | Recorder Groups & Epochs and Anchors tables each keep constant column ideal widths across resize (no NaN-width trap, per the SwiftUI-tables memory) |
| 4 | Keyboard focus ring visible on every control in §5.1's path at default and 100% text |
| 5 | Light and dark appearance both show every state symbol distinctly (no tint-only difference) |
| 6 | Selecting the blocked panel (no recorder group) and the populated panel both keep focus on the destination segmented control until a row/button is explicitly reached (IA-13) |

## 7. Out of scope

| # | Item | Where it belongs |
| --- | --- | --- |
| 1 | Estimator algorithms (how a proposal's evidence score or residuals are computed) | WW-016/021 (Alignment engineering) |
| 2 | Waveform/graph rendering of the audio itself | Later rendering work; this spec only requires numeric/table controls to exist first (§4.2, §5.3) |
| 3 | Export of aligned/corrected audio, or any cleaned/cut deliverable | M4 (WW-023 produces internal derived assets only, per contracts §1.2) |
| 4 | Transcript or speech-driven review of content | M3 |
| 5 | Any `clockApproved` evaluator UX beyond showing the state once one exists (§1.1 U2) | WW-016 qualification (frozen holdout must pass first) |

## 8. Acceptance-criteria map (for the WW-014 PR body)

| Issue #14 criterion | Section |
| --- | --- |
| Evidence not probability | §1, §1.1 note on `evidenceScore` |
| Supported / weak / disconnected / manual / gap / unsupported states | §1.1 (U1–U9), §1.2 |
| Source / group / aligned labels | §2 |
| Anchor list, numeric positive rate/offset corrections | §3.3, §4.1, §4.2 |
| Multiple clips/epochs and audition | §4.3, §4.4 |
| Keyboard/VoiceOver and undo | §5, §4.5 |
| Blocked-state remedies | §1.1, §1.2, §3.1 |
| No reliance on drag or colour | §5.3 |
