# WW-022 review round 3: verified reconciliation and derived-cache invalidation

PR #219 remains stacked on `brandonmartinez/ww-021-alignment-pipeline`. Reconciliation now keys a
verified document by both its object and its publication stamp. Per-episode publication is
serialized across open, uncertain-publication adoption, verified save, undo and redo: an older
source-resolution continuation checks ownership before activation, while an activation already
underway completes before the newer one. Cancellation is checked after source resolution, after
waiting for prior publication and immediately before publication. Verified revisions without an
accepted map clear the coordinator's accepted-map identity. Uncertain publication adoption sets
the verified model and requests reconciliation for episodes already open in the runtime.

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

The app's unhosted test target cannot link the executable's private `AlignmentRuntime` and
`ShowDocument` types. The ordering and nil-map tests exercise the shared package reconciler
and pipeline; the app test guards their wiring and the uncertain-adoption assignments.

## Validation

- Filtered `WWAlignPipelineTests|WWDerivedTests|ForbiddenAPITests`: 130 tests across package
  targets passed with four workers; the same 130 passed under
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`.
- `WW_JOBS=4 WW_TEST_WORKERS=4 scripts/test.sh`: passed, including package, gated
  calibrations, timing passes and unhosted app tests.
