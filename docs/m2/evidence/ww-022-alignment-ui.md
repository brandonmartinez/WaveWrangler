# WW-022 review round 3: verified reconciliation and derived-cache invalidation

PR #219 remains stacked on `brandonmartinez/ww-021-alignment-pipeline`. Reconciliation now keys a
verified document by both its object and its publication stamp. Per-episode publication is
serialized across open, uncertain-publication adoption, verified save, undo and redo: an older
source-resolution continuation checks ownership before activation, while an activation already
underway completes before the newer one. Cancellation is checked after source resolution, after
waiting for prior publication and immediately before publication. Verified revisions without an
accepted map clear the coordinator's accepted-map identity. Uncertain publication adoption sets
the verified model and requests reconciliation for episodes already open in the runtime.
An interrupted open keeps its episode registered for later verified revisions but releases its
in-flight publication stamp; reopening the same verified revision retries, while a newer stamp
cannot be cleared by the older completion.

Explicit invalidation records a tombstone for each cached key. A rejected stale submission
neither clears that tombstone nor resurrects the prior candidate; history restoration skips
tombstoned keys until a fresh successful computation replaces them; the old cached payload is
never reused merely because the resubmitted key is current.

## Mutation checks (2026-10-06)

Each mutation was applied alone to the working tree, its focused test run, and the fix restored
before the next mutation. Expected failures were observed:

| Finding | Mutation | Killing test/result |
|---|---|---|
| Older document publishes last | Remove both post-resolution and pre-publication generation guards | `VerifiedDocumentReconcilerTests/olderSourceResolutionCannotPublishAfterANewerDocument`: publication log differed from `[2]` **and the older accepted-map revision replaced the newer one** |
| No accepted map leaves old identity | Reinstate early return on `acceptedRevision == nil` in the app runtime | `AlignmentRuntimeBoundaryTests/uncertainPublicationAdoptionReconcilesItsVerifiedRevision`: source-contract assertion failed; package test also exercises the nil activation against a cached dependent |
| Uncertain adoption keeps stale verified model | Remove `verifiedModel = document.payload` | `AlignmentRuntimeBoundaryTests/uncertainPublicationAdoptionReconcilesItsVerifiedRevision`: source-contract assertion failed |
| Rejected submit revives invalidated cache | Restore pre-currency-check candidate caching and tombstone removal | `DerivedJobCoordinatorTests/rejectedStaleSubmissionDoesNotReviveExplicitlyInvalidatedCache`: ready payload was unexpectedly available |
| Verified save bypasses publication ownership (2026-10-07) | Replace the accepted-save callback's guarded `runtime.activate(_:)` implementation with direct `pipeline.activate(_:)` | Unhosted `WaveWranglerTests`: `AlignmentRuntimeBoundaryTests/uncertainPublicationAdoptionReconcilesItsVerifiedRevision` failed (xcodebuild 65); guarded implementation restored and the suite passed |
| Cancelled open suppresses a retry of the same stamp (2026-10-07) | Make the publication tracker's `retry` leave the in-flight stamp reserved | `VerifiedDocumentReconcilerTests/cancelledOpenRetriesTheSamePublication` rejects the second `begin` (mutation exit 1); restoring the release passes. The app boundary test requires the guarded retry wiring |

The app's unhosted test target cannot link the executable's private `AlignmentRuntime` and
`ShowDocument` types. The ordering and nil-map tests exercise the shared package reconciler
and pipeline; the app test guards their wiring and the uncertain-adoption assignments.

## Alignment split-view sizing (2026-10-07)

The native `NavigationSplitView` detail child must not derive its min/max constraints from
Alignment's changing table, controls or audition content. The Alignment workspace now lives in a
frame-filling AppKit host with no intrinsic size and an `NSHostingView` that publishes no sizing
constraints to its parent. Its accessibility children remain exposed, and the host has an explicit
label. On macOS 27, SwiftUI's disclosure `Table` exposes an accessibility **Outline**, not a Table;
the UI probes target that native role and keep the input fields' individual identifiers.
The first full local GUI pass then exposed a separate audition crash: Swift 6's actor-executor
check trapped on AVAudioSourceNode's render thread because its callback was created inside a
main-actor method. The cursor now creates its render block outside the actor; the focused
audition case reaches its status assertion without that trap.

## Remaining GUI failure triage (2026-10-07)

The retained `24a02c7` xcresult distinguishes product defects from test defects:

- The workspace's root SwiftUI `Group` had no useful description. This was a product
  accessibility defect even when the diagnostic destination contained only text. The scrollable
  Alignment workspace now owns the `Alignment workspace` label and identifier.
- At the supported 760×440 content minimum, the unscrolled workspace clipped the action and
  audition controls. The split child still uses the no-intrinsic-size AppKit host and
  `NSHostingView(sizingOptions: [])`; an inner vertical scroll view and adaptive action/audition
  grids provide reachability without publishing content-driven split constraints.
- TM202/TM209 queried only `AXLabel` for a SwiftUI `Text` status whose visible content is exposed
  through `AXValue`; the tests now accept the same prefix from either text attribute.
- TM203's native Outline gives keyboard focus to the selected cell while AppKit's field editor
  receives application-level typing. The test now sends the edit keystrokes through the
  application after Return instead of requiring the child `TextField` AX node itself to own focus.
- TM211 raced the debug fixture's derived-job seeding and assumed there was exactly one dependent.
  It now records the exact current total and requires that same total to become stale.
- The blocked-state contrast finding was the AppKit title `Empty Alignment`, outside the blocked
  content. Its exact element and context crops, one-finding cap and narrow handler are recorded in
  `m2-gui-baseline.md`; no Alignment content finding is waived.

## Validation

- Filtered `WWAlignPipelineTests|WWDerivedTests|ForbiddenAPITests`: 130 tests across package
  targets passed with four workers; the same 130 passed under
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`.
- `WW_JOBS=4 WW_TEST_WORKERS=4 scripts/test.sh`: passed, including package, gated
  calibrations, timing passes and unhosted app tests.
