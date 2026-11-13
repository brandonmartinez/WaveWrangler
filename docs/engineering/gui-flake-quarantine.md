# GUI flake quarantine

The only existing per-change selection exception is
`ContrastEvidenceUITests.testLibraryTextContrastAcrossAppearances`,
tracked by [#218](https://github.com/brandonmartinez/WaveWrangler/issues/218).
It is a broad synthetic-Library appearance audit, not an essential
blocked/recovery safety check. Audit-infrastructure timeout evidence does not
establish that contrast is correct.

This is **selection scope, not a contrast waiver**. Omit it only when the change
does not affect Library text, appearance, contrast or that test. Include it for
affected work. Preserve its assertions and include it whenever claiming the
complete relevant class/plan. Do not remove it from plan inventory.

No other flaky test is implicitly quarantined. In particular:

| Behavior | Required treatment |
| --- | --- |
| Shared-document Undo across windows | Never skip as non-product logic |
| Autosave-off close Save/Don't Save/Cancel | Essential document safety |
| Return-based setup navigation/editing | Product keyboard behavior |
| Older-show migration prompts per tab | Product migration and byte preservation |
| Blocked/recovery contrast | Essential accessibility; not covered by the broad Library exception |

Retired owner labels, milestone exits and old physical-host commands are not
current approval gates. A new exception requires a current scoped decision,
named test/reason, issue and measurable removal criteria; do not infer one
from an old intermittent result.

## Apply the exception

Select the affected coverage explicitly in the appropriate built plan. If
omitting the one eligible method while running other contrast methods, name
those methods rather than selecting the class and assuming exclusion.
Use a ready leased VM through the [GUI pipeline](gui-testing.md).

`scripts/test.sh --ui` runs **PoC**, not the complete bundle. Regression,
Accessibility and Performance are explicit profiles with distinct coverage.
For contrast/appearance work choose Accessibility; Xcode intersects selectors
with that plan. The maintained plan checker and actual executed identities
determine scope, not a historical test count.

## Report and remove

Preserve the first failure, environment state and `.xcresult`. Classify
environment-invalid runs separately from product assertions. A later pass is
additional evidence, not deletion of the failure. A deferred audit or skipped
test is never a pass or a full-suite result.

Investigate event-synthesis/audit timeouts without weakening contrast thresholds,
native control visibility or assertions. Compare like host/display configurations;
a passing Retina run cannot clear a known 1x blocked/recovery discrepancy.
Keep that discrepancy distinct from the broad Library timeout exception.

Remove quarantine only with an identified cause/fix and repeatable successful
execution under the recorded relevant configuration. Do not silently retry,
switch to a physical host, change display settings to hide a failure, or call
an affected surface qualified while omitting its test.
