# Native review interaction contract

> **Publication notice:** This report describes archived historical evidence and phase permissions, not current execution authority. Public JSON companions are pointer-redacted and **NOT byte-identical archived mirrors**; [original versus published hashes](../planning/publication-provenance.json) are separate. Measurements, pins, artifact hashes, counts and failed controls remain unchanged. Local archive placeholders are not browsable repository links. [Current user-directed milestone policy](../planning/milestone-runbook.md) supersedes old no-issues/research-only phase restrictions without granting input consent.

**2026-10-04 · Design execution; Lead review; parent publication.**
**Disposition: candidate interaction contract and pure-state evidence, not native accessibility or human approval.**
[Exact results](native-review-contract-readiness-results.json) · [reconciliation](parallel-readiness-reconciliation.md).

This concise publication integrates Design's full `REPORT.md`, not an independent reproduction.
The full storyboard, source ledger, frozen scenarios/truth and raw transitions remain at:

```text
<research-artifacts>/research/parallel-readiness-20261004/design/
```

No application, GUI, native AX/VoiceOver, participant, PCM playback, compiler or provider operation was used.
The completed documentary M1 specification is not redone; this addresses the M3 review workspace.

## Coherent revisitable workspace

| User job | Native candidate interaction | Required continuity |
| --- | --- | --- |
| Enter Review | Episode/revision/readiness title; transcript, proposal table, timeline/interval list and inspector. | Retain episode context; readiness updates never steal focus. |
| Locate a proposal | Speaker/occurrence/context/rationale/evidence/decision/mode in a navigable native table. | Linked highlights share stable IDs, but do not change text selection/caret or auto-preview. |
| Inspect timing | Label source, clip epoch, aligned, edited and export-frame domains; expose gaps/removed intervals/seams. | Explicit occurrence/segment/side resolution; no guessed inverse or fabricated time. |
| Choose mode | Explain Shorten-all-tracks duration change versus speaker Lift with unchanged duration. | Disabled reasons remain readable; unknown/protected speech is never overridden. |
| Adjust bounds/fades | Labelled numeric fields and frame-step/menu alternatives to waveform dragging; Apply/Cancel draft. | One validated named operation; retain invalid draft; Cancel changes no canonical work. |
| Decide/Undo/Redo | Accept/Reject/Restore, native Edit commands and explicit document-review Undo while text remains first responder. | Reveal stable affected selection without moving focus or hijacking text/IME shortcuts. |
| Save/relink/resume/export | Honest local-save/cloud-unknown/denied/missing/stale and frozen-export revision states. | Preserve canonical corrections/decisions, selection and caret; no silent retarget or stale-job publication. |

Primary changes retain source-bound corrections and old decisions, invalidate derived analysis/previews/proposals and require explicit reconciliation.
Backups remain referenced; the common map governs any backup actually previewed/rendered/activated.
This **does not require exporting all backups**: MVP export remains selected-primary speaker stems.

## Coordinate and protection contract

Source `n/Fin` is not a unique episode location when a file has repeated occurrences.
Group time is `u=n/Fin+e`; supported alignment is `t=a*u+b`.
A gap has no source inverse; a removed interval interior has no edited sample.
A collapsed seam exposes before/after candidates instead of inventing one inverse.
Export uses one nonnegative half-up quantization and shared half-open intervals; requested decimals and actual frames are both visible.
Terminal endpoints are distinguished from playable samples.

Numeric editing defaults to labelled aligned Start/End. Alternative time domains require an explicit occurrence/segment/side.
Negative, nonfinite, reversed, unsupported and out-of-duration intervals refuse with a remedy.
Unknown timing/protection disables cutting; a supplied confidence value is not boundary truth or silence.
Safe Lift may be offered but is never accepted automatically.
Final merged fade footprints require Pipeline/Alignment validation, not only Design's supplied safety flags.

## Accessibility obligations, not measured passes

All waveform actions have proposal/interval-list, numeric, menu or button equivalents.
Expose semantic headings/rows/fields/actions, units, current/error values, readable disabled reasons and explicit refocus commands.
Decorative waveform samples are not thousands of accessibility elements.
Linked highlighting/background completion does not move first responder, caret or VoiceOver cursor.
Preserve normal Space, composition and text Undo; transport shortcuts are conditional on nontext focus and native/FKA/VoiceOver behavior.
Announce useful decision/stale/recovery results, not every playhead or progress update.
Native traversal, announcements, 200% text, contrast, reduced motion and human comprehension remain operator gates.

Design reviewed substantive Apple DocC content on 2026-10-04:
[accessibility](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/accessibility.json),
[VoiceOver](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/voiceover.json),
[keyboards](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/keyboards.json),
[focus/selection](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/focus-and-selection.json),
[Undo/Redo](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/undo-and-redo.json),
[drag/drop](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/drag-and-drop.json),
[progress](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/progress-indicators.json),
[text fields](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/text-fields.json),
and [accessibility testing](https://developer.apple.com/tutorials/data/documentation/accessibility/performing-accessibility-testing-for-your-app.json).
These support the contract; documentary verification is not app conformance.
`SOURCE_LEDGER.md`, retrieval hashes and content-review records remain in the scratch root.

## Finite state evidence

Inputs and exact expected checkpoints were separately authored/frozen before the reducer existed.
One serial run: **24/24 scenarios pass; six defective controls detected; zero unexpected failures**.
Scenarios cover overlap/timing refusal, draft cancellation, focus/caret, text Space, repeated occurrences, gaps/seams/rounding, mode changes, Undo/Redo, primary/correction invalidation, Save/relink unknowns and newer-schema refusal.
Positive safe-Lift/Shorten, explicit preview and simulated successful Save prevent an always-disabled implementation from passing.

Controls detect waived overlap, cancel focus theft, text-Space interception, silent first-occurrence choice, correction loss and stale export.
All safety/human-event/focus/caret/job/save values are **synthetic tokens**, not audio truth, native controls, disk or actual human acceptance.
One proposal, two unity-rate occurrences and two supported spans do not validate arbitrary timelines/history/concurrency.
Two frozen input files remain unchanged; no independent authorship/reproduction.

## Owned next protocol

**Design, Mac feasibility review recommended 2026-10-05:** propose a separately consented Review-only native prototype.
The full source report names OP01-OP07: keyboard/IME/caret, overlap/mode comprehension, coordinates/inverses, Undo/filter/refocus, primary/correction/stale jobs, Save/relink/unknowns and VoiceOver/visual settings.
App compile/open/capture, settings, operators/participants, listening and provider work require explicit scope.
No prototype or pilot is authorized here.
WW-014/025 remain partial; WW-029/044/035 receive planning inputs while pending; no WW-004, M1 or M3 completion follows.
