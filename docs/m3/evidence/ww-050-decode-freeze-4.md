# M3 decoder witness-bound cursor freeze candidate

Date: 2026-10-10. Refs #23 #32. The [M3-DECODE-004 candidate](../../m2/fixtures/m3-freeze-decode-4.json)
prospectively supersedes only the **active decoder tree pin**. Both historical M2
freezes and the [M3-DECODE-003 freeze](../../m2/fixtures/m3-freeze-decode-3.json)
remain unchanged, as do their one-shot holdout records. The [revision-3
addendum](ww-050-decode-freeze-3.md#post-merge-synthetic-holdout-addendum-2026-10-10)
records the completed M3-DECODE-003 holdout; its earlier pre-merge "not run"
text describes only the earlier point in time.

This revision pins WWDecode source tree
`21130e376b6c8cb6bd56eb8aa9152007867a0ce3` and WWDecode test tree
`1f793b5dec9f1095ced2cdc5ff6f48e11d5e9b97`. The package-only
witness-bound cursor routes an independently supplied `RawSourceIdentity` into
the system gateway's descriptor comparison **before parser callbacks**;
synthetic tests cover immediate pathname replacement (zero parser reads),
unchanged stereo PCM channel/window bounds, post-read mutation, cancellation,
and rejection of a gateway without descriptor binding. The ordinary cursor
remains unchanged. No application issuer or source consent is created.

## Fresh synthetic calibration, not holdout

`M3-DECODE-004` uses fresh SHA-256-derived calibration and holdout seeds,
checked disjoint from M2-DECODE-001/002 and M3-DECODE-003. The prior recipe,
generator draws, generator-derived truth, measurement, 130/520 case counts,
seven gates and thresholds are identical JSON values; the always-on tests
compare the preceding record digest and these definitions. The 130 new
calibration cases plus output-settings record ran with `umask 022`,
`--jobs 2 --parallel --num-workers 2`,
`WW_DECODE_CALIBRATION=1`, `WW_M2_FREEZE_MAX_CONCURRENCY=2`, and
`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=2`. The single selected
calibration test passed. Its 131 ordered [records](ww-050/calibration-4.jsonl)
have SHA-256 `0eb1ddee52689db2f20b84993292b8edeecbadbf8a18e1c6570443dbf8df1f08`.

All inherited gates passed: 90 supported cases / 2,225,115 frames with zero
mapping failures; 996 landmark observations (986 lag 0, 9 lag +1, 1 lag -1),
none below correlation; 48 exact cases; 40 planted cases with expected errors,
zero mutations or publications; and zero output-settings failures. Every
stratum has 10 calibration cases. This calibration exercises the unchanged
push decoder; the separate witness-bound cursor tests establish the new
pre-parser refusal. Neither can issue trusted selected-Primary access.

**Revision-4 holdout NOT RUN.** `WW_M3_DECODE_4_HOLDOUT=1` alone enables its
fresh 520-case split; that test checks both tree pins before materializing a
case. Independent review of this prospective freeze and merge of an exact
clean source/test tree must precede the sole revision-4 holdout;
report all 521 ordered records, SHA-256, host, commit and every gate without
relabeling or rerunning any earlier holdout. A fresh cumulative safety review
and full exact-head test gate are still required before merging this PR.
