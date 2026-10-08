# GUI flake quarantine

**M3 per-PR quarantine list: one test.** The only eligible test is
`ContrastEvidenceUITests.testLibraryTextContrastAcrossAppearances` from #218.
It audits contrast and records measurements for a synthetic Library in four
appearances. It does not audit blocked or recovery surfaces. The M2 baseline
defines essential `.contrast` checks only for blocked/recovery surfaces and
classifies broad Library appearance checks as nonessential accessibility
qualification. #218 classifies the observed failure as an audit-infrastructure
timeout, not a product finding. The test therefore meets M3's per-PR quarantine
rule for named non-product-logic, non-essential-accessibility tests.

This is a per-PR test selection only, not a contrast waiver or a change to the
audit. Do not omit the test when a PR changes Library text, appearance, or
contrast behavior, or changes this test. The audit itself must not be weakened.
The test remains in every capped full UI suite and milestone-exit suite.

| Named test | Live issue owner · fix target | Classification |
| --- | --- | --- |
| `CoreTasksKeyboardUITests.testT24TwoWindowsSharedUndo` | [#215](https://github.com/brandonmartinez/WaveWrangler/issues/215): Lead (`owner:lead`); complete the issue's T24 evidence/window-offset acceptance and demonstrate three consecutive full-suite passes. | **Never skip.** Verifies shared-document undo behavior; a window overlap may explain the flake, but does not make the behavior non-product logic. |
| `DocumentLifecycleUITests.testAutosaveOffCloseOffersSaveDontSaveCancel` | [#215](https://github.com/brandonmartinez/WaveWrangler/issues/215): Lead (`owner:lead`); classify event-synthesis timeouts separately and meet the issue's three-consecutive-full-suite-pass acceptance. | **Never skip.** Verifies Save / Don't Save / Cancel and preservation of unsaved edits; essential document safety. |
| `EpisodeSetupUITests.testReturnOnGroupedRowFocusesFirstEditableField` | [#215](https://github.com/brandonmartinez/WaveWrangler/issues/215): Lead (`owner:lead`); wait for menu/submenu items and meet the issue's three-consecutive-full-suite-pass acceptance. | **Never skip.** Verifies Return-based keyboard navigation and editing. |
| `ContrastEvidenceUITests.testLibraryTextContrastAcrossAppearances` | [#218](https://github.com/brandonmartinez/WaveWrangler/issues/218): Design (`owner:design`); diagnose/bound audit timeouts without weakening the contrast audit, then demonstrate three consecutive successful full-suite executions of this test on a claimed GUI host. | **Per-PR quarantine eligible.** Broad synthetic-Library appearance/contrast evidence, not an essential blocked/recovery contrast check; omit only under the surface/test-change conditions above. |
| `FormatUpdateUITests.testT21EachTabbedOlderShowAsksWhenSelected` | [#231](https://github.com/brandonmartinez/WaveWrangler/issues/231): Mac (`owner:mac`); make tab selection deterministic and demonstrate three consecutive Mac mini passes without loosening assertions. | **Never skip.** Verifies per-tab migration prompts and byte-preservation of older shows; this is product migration behavior. |

The issue owner and fix targets above reflect the live issue labels,
descriptions, and comments checked for this revision. The `owner:*` labels are
informational, not assignees; no separate M3 test-fix owner is inferred.

## Per-PR GUI selection

Run affected UI coverage and essential accessibility checks under the
coordinator's GUI lease. When `ContrastEvidenceUITests` is the affected class
but the PR does not change Library text, appearance, contrast behavior, or
this test, omit only the quarantined test by selecting the class's other
methods explicitly:

```sh
scripts/test.sh --ui \
  -only-testing:WaveWranglerUITests/ContrastEvidenceUITests/testTextSize200Screenshots \
  -only-testing:WaveWranglerUITests/ContrastEvidenceUITests/testLibraryMessageBarAt200 \
  -only-testing:WaveWranglerUITests/ContrastEvidenceUITests/testVisualOverridesLightDarkReduceMotion200 \
  -only-testing:WaveWranglerUITests/ContrastEvidenceUITests/testAccentTintedControls \
  -only-testing:WaveWranglerUITests/ContrastEvidenceUITests/testSystemVisualSettings \
  -only-testing:WaveWranglerUITests/ContrastEvidenceUITests/testSaturationZeroShowWindow
```

If the PR changes any excluded test's surface or behavior, include that test in
the affected selection. Otherwise this selector list is a per-PR scope, not a
substitute for the complete class or suite. No other test may be omitted under
this list.

## Capped full GUI suites

Run the complete UI test bundle without any selector:

```sh
scripts/test.sh --ui
```

With no selector, `scripts/test.sh` passes `-only-testing:WaveWranglerUITests`
to Xcode. This runs the full UI bundle and does not consult or apply this
per-PR quarantine list. Capped full suites and milestone-exit suites must
remain unfiltered and include every test, including the #218 test. If a listed
issue test fails in a full suite, record the failure against that issue; never
silently retry it away or count a skipped test as a pass.
