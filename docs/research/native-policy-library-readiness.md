# Native policy and canonical-library readiness

> **Publication notice:** This report describes archived historical evidence and phase permissions, not current execution authority. Public JSON companions are pointer-redacted and **NOT byte-identical archived mirrors**; [original versus published hashes](../planning/publication-provenance.json) are separate. Measurements, pins, artifact hashes, counts and failed controls remain unchanged. Local archive placeholders are not browsable repository links. [Current user-directed milestone policy](../planning/milestone-runbook.md) supersedes old no-issues/research-only phase restrictions without granting input consent.

**2026-10-04 · Mac execution; Lead review; parent publication.**
**Disposition: finite evidence accepted with limits, not production or architecture approval.**
[Exact results](native-policy-library-readiness-results.json) · [cross-lane reconciliation](parallel-readiness-reconciliation.md).

## Scope and provenance

This is a concise integration of Mac's `REPORT.md`, not an independent reproduction.
Original code, literal expected truth, logs, retained failures and source report are under:

```text
<research-artifacts>/research/parallel-readiness-20261004/mac/
```

Only newly generated local metadata/markers and windowless native APIs were exercised.
No repository application, recordings, provider folder, GUI, model, dependency installation or permission settings were used.
Host: macOS 27.0.1/build 26A434, arm64, 128 GiB; Python 3.14.8 and Swift 6.4.
Native compilation targeted macOS 26 in **Swift language mode 5**; this is not runtime-26, strict-Swift-6 or 16-GB validation.

## Actual findings

| Contract | Observed evidence | Boundary |
| --- | --- | --- |
| Canonical library | 26 cases: complete rich/empty objects, unknown-newer refusal, corruption, ordering, collections/comments/unavailable entries and failed publication. | JSON/prior candidate only; no native library UI, concurrency or provider proof. |
| Synthetic V0 migration | Four cases retain original/backup bytes and complete human work, including expected failures. | Not an existing production format or package/SQLite migration. |
| History/primary changes | 16 cases validate complete snapshots, state at cursor, the redo tail and two actions: choose-primary and set-comment. | One episode/speaker; no general editing schema, branching, retention, concurrent jobs or native UndoManager proof. |
| Local reference model | Seven generated-marker cases, including explicit relink and identity refusals. | Generated digests are not permission to read/hash real source media. |
| Native queued autosave | One genuine OFF-before-callback/ON pair; two periodic AppKit callbacks, stock `writeSafely`, full-envelope disk comparisons. | Subclass policy, versions disabled; not the earlier GUI app's regression or OFF during an in-flight write. |
| Bookmark identity | An actual plain bookmark resolves the old filename's replacement after the original is moved; `stale=true`. | Bookmark/path resolution is not identity approval or security-scoped access. |
| Dirty Quit | Corrected before-native-terminate interception compiles. | No decision hook, Save/Cancel sheet, Close/Dock/system Quit or application instance was exercised. |

The final local denominator is **53 distinct cases: 9 accepts, 9 whole-prior read-only recoveries and 35 expected refusals; zero unexpected failures**.
Current/prior/cache bytes are compared, not only selected fields. Recognizable newer library schemas refuse load, Save and downsave before fallback; an unreadable header only permits read-only recovery.
Missing/corrupt canonical files are not recreated from a derived cache.
Post-publication errors remain **acknowledgement-uncertain**, not successful Save.

## Native race: what was actually established

`raw/native-events.json` records dirty revision 1, native scheduling, OFF, the real queued callback, unchanged original revision 0 and retained dirty state.
Re-enabling ON and making a new revision-2 edit automatically invokes native scheduling/publication.
The complete independent disk value matches after **0.507011791 seconds**.
One finite observation meets the provisional two-second target; it does not establish product cadence or all timing interleavings.

**Do not adopt this probe's OFF callback contract.** It returns `nil` without publication to acknowledge the automatic request; that is not a successful Save.
The probe preserves dirty state, but native close paths can interpret an autosave completion as permission to close.
Explicit cancellation/close coordination and in-flight-write policy therefore need separate integration evidence.
Earlier cancellation-based prototypes and their GUI limitations remain unchanged; this is a different, windowless witness.

[Apple's `terminate(_:)` documentation](https://developer.apple.com/documentation/appkit/nsapplication/terminate(_:)) places unsaved-document processing before `applicationShouldTerminate`.
The retained delegate-only candidate is too late. `probes/BeforeNativeQuit.swift` intercepts before `super.terminate`, but is **compile-only**, not a verified fix for every exit route.

## Corrections, controls and reproducibility

Three bounded cycles: an isolation compile failure; a corrected native probe plus 52/53 local comparisons; then correction of L26's erroneous expectation and a new compile-only Quit module.
L26 already refused damaged-current Save and preserved bytes; only its comparator changed.
Final 53 cases overlap the earlier 53, not another independent population. Native execution was not repeated.
All failures, source snapshots and `freeze/cycle{2,3}-manifest.json` remain retained.

Exact commands/version output are in `raw/compile-cycle*.command.json`, `raw/versions.json` and `raw/final-verification.json`.
Three serial compiler invocations, one native test child, no ongoing owned processes.
Four additional unsafe reference controls are simulated contrasts; the bookmark replacement is an actual API counterexample.

## Remaining gates and owned action

**Mac, Lead review recommended 2026-10-05:** scope native Close/Quit/explicit-Save/in-flight-OFF tests, scoped grants/regrant and publication lineage.
No app opening or follow-up trial is authorized here.
`PROVIDER_PLAN.json` proposes a fresh **iCloud-only** generated-content folder and separately named devices; it was not executed and establishes nothing about OneDrive/Dropbox.

SQLite is explicitly excluded: the previous fresh-constructor-before-recovery defect remains unresolved.
General history/primary validation, provider/conflict/recovery, sandbox grants, native accessibility and reference-device gates stay open.
WW-003/005/006/008/049 gain evidence only; their status, accepted criteria and production gates do not change.
