# GUI flake quarantine

**Reviewed M3 list: empty.** None of the tests named in [#215](https://github.com/brandonmartinez/WaveWrangler/issues/215), [#218](https://github.com/brandonmartinez/WaveWrangler/issues/218), or [#231](https://github.com/brandonmartinez/WaveWrangler/issues/231) is safe to quarantine. Their intermittent failures are attributed to test or runner infrastructure, but the tests protect product behavior or essential accessibility. Do not add an exclusion without reviewing the named test, confirming its issue records an owner and fix target, and merging that change.

| Named test | Issue owner · fix target | Classification |
| --- | --- | --- |
| `CoreTasksKeyboardUITests.testT24TwoWindowsSharedUndo` | [#215](https://github.com/brandonmartinez/WaveWrangler/issues/215): Lead (`owner:lead`, quarantine-rule owner); Mac (M3 test-fix owner); complete the issue's T24 evidence/window-offset acceptance and demonstrate three consecutive full-suite passes. | **Never skip.** Verifies shared-document undo behavior; a window overlap may explain the flake, but does not make the behavior non-product logic. |
| `DocumentLifecycleUITests.testAutosaveOffCloseOffersSaveDontSaveCancel` | [#215](https://github.com/brandonmartinez/WaveWrangler/issues/215): Lead (`owner:lead`, quarantine-rule owner); Mac (M3 test-fix owner); classify event-synthesis timeouts separately and meet the issue's three-consecutive-full-suite-pass acceptance. | **Never skip.** Verifies Save / Don't Save / Cancel and preservation of unsaved edits; essential document safety. |
| `EpisodeSetupUITests.testReturnOnGroupedRowFocusesFirstEditableField` | [#215](https://github.com/brandonmartinez/WaveWrangler/issues/215): Lead (`owner:lead`, quarantine-rule owner); Mac (M3 test-fix owner); wait for menu/submenu items and meet the issue's three-consecutive-full-suite-pass acceptance. | **Never skip.** Verifies Return-based keyboard navigation and editing. |
| `ContrastEvidenceUITests.testLibraryTextContrastAcrossAppearances` | [#218](https://github.com/brandonmartinez/WaveWrangler/issues/218): Design (`owner:design`, issue owner); Mac (M3 test-fix owner); diagnose/bound audit timeouts without weakening the contrast audit, then demonstrate three consecutive successful full-suite executions. | **Never skip.** Runs the essential contrast audit; an infrastructure timeout is not grounds to suppress a genuine accessibility finding. |
| `FormatUpdateUITests.testT21EachTabbedOlderShowAsksWhenSelected` | [#231](https://github.com/brandonmartinez/WaveWrangler/issues/231): Mac (`owner:mac`); make tab selection deterministic and demonstrate three consecutive Mac mini passes without loosening assertions. | **Never skip.** Verifies per-tab migration prompts and byte-preservation of older shows; this is product migration behavior. |

The issue owners and repair targets above were checked against the live issue labels, descriptions, and comments before this list was written. They remain the source of truth for repair status and acceptance.

## Per-PR GUI selection

Run the affected class or test explicitly under the coordinator's GUI lease. For example:

```sh
scripts/test.sh --ui -only-testing:WaveWranglerUITests/FormatUpdateUITests/testT21EachTabbedOlderShowAsksWhenSelected
```

This is selection of the per-PR test scope, not a quarantine exclusion. The approved quarantine set is empty, so no named test is removed from an affected-class selection.

## Capped full GUI suites

Run the complete UI test bundle without any `-only-testing` argument:

```sh
scripts/test.sh --ui
```

With no selector, `scripts/test.sh` passes `-only-testing:WaveWranglerUITests` to Xcode. This runs the full UI bundle and does not consult or apply this per-PR quarantine list. Capped full suites and milestone-exit suites must remain unfiltered and include every test. If a listed issue test fails in a full suite, record the failure against that issue; never silently retry it away or count a skipped test as a pass.
