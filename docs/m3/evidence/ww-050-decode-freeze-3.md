# M3 decoder source-boundary freeze candidate

Refs #23 #32. Date: 2026-10-09. This new `M3-DECODE-003` revision supersedes the
**active tree pin**, not the historical M2 evidence. Both
[`m2-freeze-decode.json`](../../m2/fixtures/m2-freeze-decode.json) and
[`m2-freeze-decode-2.json`](../../m2/fixtures/m2-freeze-decode-2.json), their
calibration files, and their sole holdout records remain byte-for-byte unchanged.
The [new candidate record](../../m2/fixtures/m3-freeze-decode-3.json) carries
fresh seeds, two new source/test tree IDs, and the unchanged M2 recipe, truth,
measurement, case counts (130 calibration / 520 holdout), seven gates and
thresholds. The always-on tests compare those definitions and the earlier
record digest, check disjoint seeds across both prior namespaces and splits,
and recompute both tree IDs from working files: `Sources/WWDecode`
`4a1b0d919928facc61a1dc18e092c5f8519a417c` and `Tests/WWDecodeTests`
`3c3f339ad4b271af2287f1b23ebbb3a68843ce6c`. The approved production
`SourceDecoder.swift` and `SystemSourceContentIO.swift` retain their reviewed
`5a2899c` contents without edits in this freeze revision.

## Synthetic calibration (not holdout)

On Apple M5 Max, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4:
with test `umask 022`, `--jobs 2 --parallel --num-workers 2`,
`WW_M2_FREEZE_MAX_CONCURRENCY=2`, `WW_DECODE_CALIBRATION=1`, and private
scratch/log, the single `DecodeCalibrationTests/calibrationSplitMeetsEveryGate`
test **passed**. The 131 ordered [case records](ww-050/calibration-3.jsonl)
have SHA-256 `71b534cc7036c049c22e5dc09d9ffd3cb23542d665f1ced8ece363aa3b2f072a`:
90 supported cases / 2,250,986 frames, zero mapping failures; 981 landmarks,
960 lag 0 and 21 lag +1, none below correlation (minimum lossy 0.630882);
49 exact cases; 40 planted cases with expected errors, zero mutations and
publications; zero output-settings failures. All 13 strata have 10 cases.
This measures synthetic decode truth, not the new pre-open gate itself; the
separate always-on raw witness tests establish zero source descriptor opens
on known-nonlocal/unknown metadata, with no consent issued or Backup opened.

The pre-repair known-nonlocal case at unchanged `dfcb075b` was **RED**:
exit 1, one test / three assertions, source opener called once. The approved
`5a2899c` repair gave a diagnostic focused 84/84 WWSources and 86/86 WWDecode
after excluding only the historical M2 pinned-tree check; the unfiltered
WWDecode run failed its genuine old-pin check (86/87, two mismatches).
Revision-3 targeted checks **passed without exclusions**: WWSources
`ForbiddenAPITests` 12/12 and WWDecode 22/22, including the full new
`DecodeFreezeTests` pin, inherited definitions, disjoint seed/recipe and
calibration-record recomputation, as well as the raw witness cases. The
holdout was explicitly skipped. Independent whole-diff review and a fresh
full `scripts/test.sh` on the exact clean head are **still required**
before any merge claim.

**Holdout NOT RUN.** `WW_M3_DECODE_3_HOLDOUT=1` is the only new holdout switch;
after the freeze merges, a distinct, clean, tree-matched one-shot 520-case run
must record its result as-is. Neither M2 holdout may be rerun or relabelled.
This synthetic gate does not authorize original media, models, network access,
selected-Primary issuance, or source/Backup mutations.

## Post-merge synthetic holdout addendum (2026-10-10)

The preceding **Holdout NOT RUN** statement is the pre-merge status record. After
[#436](https://github.com/brandonmartinez/WaveWrangler/pull/436) merged to main
at `03c34982c1af6230bd49889c7b753c938470f29c`, the distinct M3-DECODE-003
one-shot ran on a physical Mini Mac14,12 from a clean exact source head
`9efbc16f91ce28e6823a6d85e363cd3dde9b095e`, with pinned WWDecode tree
`4a1b0d919928facc61a1dc18e092c5f8519a417c` and test tree
`3c3f339ad4b271af2287f1b23ebbb3a68843ce6c`. The independently
static-approved private runner SHA-256
`ac1b5fc3cca29e4e1accf805c47912ab4a59db03119d6056d2291e090ef875a9` and
one-time JIT SHA-256
`18489b2241581067b7f929b538cd8c233f665fb40a801ea00d6b77397b7c4226` were
hash-verified before use.

The selected `DecodeCalibrationTests/holdoutSplitMeetsEveryFrozenGate` test
passed **1/1**; Swift, timeout, and driver exits were each 0. It produced 520
deterministic synthetic cases (13 strata x 40: 360 supported and 160 planted)
and one output-settings record: 521 ordered JSONL rows with SHA-256
`12bb3baa2081be7b97bff327811fa8be47c9a7ed35c9acd9a02a619440f5f761`.
There were zero planted mutations or publications. The checkout was unchanged
and clean after the run, with no post-run native roots or GUI holder.

**Current status: PASS — M3-DECODE-003 synthetic holdout only.** Historical M2
holdouts were not rerun. This result does not authorize recordings, model or
network inference, Backup access, user original source-content opens or writes,
speech-rights claims, selected-Primary issuance, or product acceptance. The
scoped public record is on [#23](https://github.com/brandonmartinez/WaveWrangler/issues/23#issuecomment-6093569045);
[#23](https://github.com/brandonmartinez/WaveWrangler/issues/23) and
[#32](https://github.com/brandonmartinez/WaveWrangler/issues/32) remain open.
