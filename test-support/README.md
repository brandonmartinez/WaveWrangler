# Test support

This directory holds durable test inputs and historical qualification records,
not the current product or developer guides. Start at [docs/](../docs/README.md)
for those.

## Qualification records

`qualification/` preserves frozen decoder, estimator, discontinuity, time-map,
and renderer definitions, fixture registries, scored JSONL records, and the
protocols needed to interpret them. These records were moved from the retired
milestone documentation without changing their bytes.

The `m1`, `m2`, and `m3` names identify historical qualification revisions; they
are not a current roadmap. Supporting reports describe the code, measurements,
hardware, and permissions at the time. They do not establish current product
qualification or authorize new media access, holdout runs, or physical-host tests.
Old screenshots, planning diaries, and superseded design documents remain in Git
history rather than the live documentation tree.

## Immutable evidence versus maintenance

- Keep freeze JSON, registry entries, seeds, scored records, historical
  `pinnedTrees`, and recorded SHA-256 values immutable.
- `qualification/source-tree-baselines.json` separately pins the **current**
  source and test trees for maintenance checks. Updating `currentTrees` is not
  a new DSP qualification.
- `SourceTreeBaseline.requireHistoricalTrees` still requires the exact original
  source trees before a historical holdout can run. Never substitute maintenance
  pins or enable holdouts as part of routine documentation maintenance.

Original serialized paths such as `docs/m2/fixtures/...` intentionally remain
inside the immutable evidence. Tests resolve these through
`SourceTreeBaseline.artifactURL(recordedPath:repository:)`, which maps only the
retired `docs/m1`, `docs/m2`, and `docs/m3` namespaces to this directory and rejects
traversal. Other historical document references identify records available in
Git history, not current navigation links.

For changes to these helpers, use the focused suites in
`WWTestSupportTests`, `WWAlignEstimateTests/HoldoutTests`,
`WWAlignSegmentTests/SegmentFreezeTests`, `WWTimeMapTests/TimeMapFreezeTests`,
`WWRenderTests/RenderFreezeTests`, and `WWDecodeTests/DecodeFreezeTests`.
Leave opt-in calibration and holdout environment variables unset. See the
[testing guide](../docs/engineering/testing.md) for the established runner,
worker limits, and local-media consent requirements.
