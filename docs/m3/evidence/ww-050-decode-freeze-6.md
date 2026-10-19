# Revision-6 decoder freeze candidate

Date: 2026-10-19. Refs #23 #32.
**CANDIDATE ONLY: independent review and explicit activation/merge are pending.**
The user authorized preparation and 130 generated calibration cases, not a holdout,
commit, push, pull request or merge. Passing candidate consistency tests is not
approval, an effective freeze, or exact-clean-head qualification.

## Cause and prospective scope

The isolated baseline-repair worktree starts at
`e04233576ef358723b4696da9b19372114f505c4`. The original three selected baseline
failures were reproduced there before edits. The relink and decoding-boundary
repairs are separate from this prospective re-freeze.

Commit `56b779c4` has the exact source/test trees pinned by
[`m3-freeze-decode-5`](../../m2/fixtures/m3-freeze-decode-5.json):
`6e5dfb23753f2ee0983b487e3adad330ab9702ea` and
`35d2f10f43faac317f4bd19962fae034eb9df7ab`.
Commit `7b1ad2dd` subsequently added only
`Sources/WWDecode/PCMResampling.swift` and
`Tests/WWDecodeTests/PCMResamplingTests.swift` inside those boundaries, without
renewing the freeze. The source tree became
`595479f63c110ae898a3f57167d7689d327745f7` and test tree
`a0128edc4c81b63bfc45cdef87978eba7341dc0d`.
The integrity failure was genuine drift, not a hashing error or a model-branch
decoder change.

The [revision-6 candidate](../../m2/fixtures/m3-freeze-decode-6.json) pins the
unchanged production source tree
`595479f63c110ae898a3f57167d7689d327745f7` and candidate test tree
`dd95cf636fea513f98b061f905768c4a7497fc57`.
The test changes introduce the fresh `M3-DECODE-006` namespace, dedicated
`calibration-6.jsonl` / `holdout-6.jsonl` names, revision-5 historical-definition
checks and a synthetic tree-ID regression proving that edited and added files
still change the pin. Both flat directory IDs are recomputed from working bytes;
no exclusion or weakened comparison is introduced.

All five older freeze JSON files, their evidence and their preexisting registry
entries remain unchanged. Revision 5's SHA-256 is
`190aff34148feabbc9c7ad222bb830b77c4d9ef435c026a2dc90330f8d54ec63`,
checked by the new historical-definition test. The new registry entry is a
candidate, not a declaration that revision 5 has been activated or superseded.

## Unchanged recipe and gates

The recipe, generator-derived truth, measurement, count justification, verbatim
gate, all seven gate definitions, gate values, missing-evidence rule and three
version values are identical JSON values to revision 5. Counts remain 130
calibration and 520 holdout cases. The candidate seeds are checked disjoint from
each other and from every earlier calibration and holdout namespace.

The 13 strata remain AAC/M4A, AAC/CAF, Opus/CAF, ALAC, FLAC, integer PCM, float
PCM, packet boundary, variable rate, truncated, corrupt, unsupported and stale.
The calibration contributes 10 cases per stratum: 90 supported, 40 planted and
one split-level output-settings record.

Decode calibration exercises the existing push decoder, not nominal resampling.
Separate `PCMResamplingTests` cover helper timing/channel identity, discrete
multichannel preservation, invalid input and cancellation. Neither supplies a
real-media, offline-inference, protected-edit, other-OS or MVP acceptance claim.

## Fresh generated calibration, not holdout

Host: Apple M5 Max, 18 cores, 128 GiB; macOS 27.0.1 (26A434), Xcode 27.0
(27A266a), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`).
The candidate is uncommitted on the baseline head above. The 13 cheap
definition/seed/registry/tree-integrity controls passed before calibration,
with no audio files generated or decoded by those controls.

**Calibration PASS, all seven unchanged gates.** After the coordinator granted
the sole bounded calibration lease, a live process check found no competing
WaveWrangler, xcodebuild, swift-build or swift-test process. The one-minute load
was 12.90 at the start. The command, from the repository root with the user's
shell configuration loaded and `umask 022`, was:

```bash
WW_DECODE_CALIBRATION=1 WW_M3_DECODE_6_HOLDOUT=0 \
WW_M2_FREEZE_MAX_CONCURRENCY=1 WW_ESTIMATOR_MAX_CONCURRENCY=1 \
WW_DECODE_RECORDS_DIR="$PWD/docs/m3/evidence/ww-050" \
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
swift test --package-path Packages/WaveWranglerKit \
  --scratch-path .build/swiftpm -c release -Xswiftc -DDEBUG \
  --jobs 2 --no-parallel \
  --filter DecodeCalibrationTests/calibrationSplitMeetsEveryGate
```

Exactly one selected test passed (1.675 seconds), with original exit `0`.
The raw run spans `2026-10-19T05:21:43Z` through `2026-10-19T05:21:50Z`.
One generated case ran at a time; no holdout was enabled. The complete artifacts
are:

- [131 ordered records](ww-050/calibration-6.jsonl), SHA-256
  `de5ec2face99faed17fc8cecc0db00e2eba847355a6d29e41720dc4d6cd0b037`.
- [Original run log](ww-050/calibration-6-run.log), including the base commit,
  working source/test pins, original exit and UTC bounds, SHA-256
  `2dc01a4ae8136a4bf37d8ac3ce55ea2d2d24f90992228592c7ebeeceee2f8d17`.

There are 130 calibration cases in index order, followed by one output-settings
record. All 13 strata contribute exactly 10 cases. The 90 supported cases
total 2,337,439 frames and have zero mapping failures; all 48 exact cases are
bit-exact. The 1,107 landmark observations have lag 0 for 1,088, +1 for 18,
and -1 for one; zero observations are below the unchanged correlation
thresholds. Minimum observed correlation is `0.6264418363571167`.
All 40 planted cases match their expected typed errors with zero mutations
or stale publications, no open readers and balanced security scopes.
The split-level output-settings record has zero failures.

| Inherited gate | Observed | Unchanged limit | Result |
| --- | --- | --- | --- |
| supported-mapping | 0 failed/changed/unpublished supported cases | 0 | PASS |
| landmarks | maximum absolute lag 1; 0 below correlation | at most 1 frame; 0 below correlation | PASS |
| planted-explicit-error | 0 cases without the expected error | 0 | PASS |
| planted-no-mutation | 0 changed planted sources | 0 | PASS |
| planted-no-stale-publication | 0 publication/lifecycle/resource failures | 0 | PASS |
| output-settings | 0 failures | 0 | PASS |
| strata-coverage | 0 missing strata | 0 | PASS |

No revision-6 holdout files were generated or decoded. The calibration/performance
lease was released immediately after completion; no app/build/test process was
left running. This is working-tree candidate calibration, not a clean committed
or approved freeze run.

## Focused regression verification

After recording the calibration summary, 42 focused controls passed: relink
acceptance/refusal, recursive decoding-boundary policy, the Setup regrant
adapter, inherited gates/seed disjointness, all historical definitions, candidate
tree integrity, registry and recorded-calibration reproduction, header-only cursor
lifecycle, and bounded PCM conversion. The repeat-calibration and unapproved
holdout tests were disabled in that verification pass; the authorized generated
calibration ran separately exactly once.

The three original failing selectors were also rerun together and all passed:
`RelinkTests/confirmedCaptureRefusesDuplicateStaleChangedAndInaccessibleCandidate`,
`ForbiddenAPITests/noOtherModuleOrTheAppDecodes`, and
`DecodeFreezeTests/decoderAndHarnessTreesMatchTheFreezeRecord`.
That last check now verifies the explicitly labelled revision-6 candidate, not
retroactive revision-5 approval. The isolated headless Debug app build had
already passed for the unchanged production repair bytes. No app was launched.

## Remaining approvals and qualification

**Revision-6 holdout NOT RUN and NOT AUTHORIZED.** A separately approved one-shot
520-case run requires independent review, explicit activation and merge, an exact
clean matching source/test tree, and reporting of its original exit, host, commit,
all 521 ordered records, digest and every unchanged gate. No earlier holdout may
be rerun or counted for this candidate.

Independent cumulative review and the full applicable exact-clean-head
`scripts/test.sh` gate remain pending. Candidate-byte integrity and focused tests
do not replace either requirement. No private recording, model, network
inference/upload, provider trial, app launch or GUI run is part of this evidence.
