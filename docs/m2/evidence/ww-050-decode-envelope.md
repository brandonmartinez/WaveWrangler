# WW-050 part 1: WWDecode decode envelope (synthetic evidence)

Refs #45. Host: Apple M5 Max, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4. Code measured: the commit that
adds this note on `brandonmartinez/ww-050-decode-engine` (PR head; SHA in the PR); `DecodeEnvelope.version` 1, `FormatInterpretation.currentVersion` 1, envelope
SHA-256 pin `0ad289ec…0ebb7fa` (`DecodeEnvelopeTests`). Commands, from `Packages/WaveWranglerKit`:
`swift test --scratch-path .build/swiftpm --filter WWDecodeTests` (40 tests, 5 suites, pass) and `--filter ForbiddenAPITests` (8 pass);
then `scripts/test.sh`. Every fixture is generated in `$TMPDIR` by the native writers (AVAudioFile/ExtAudioFile): planar noise plus
three Hann-windowed chirp landmarks per channel at known source frames. Each one is decoded through `SourceDecoder` with rotating
chunk sizes (7 / 333 / 1000 / 4096 / 65 536 frames). "Lag" is |located landmark − truth| in output frames, measured after priming and
remainder trimming. Output frame *n* is source frame *n* at the source rate.

| Container / codec | Sample formats | Rates (Hz) | Channels | Fixtures | Result |
|---|---|---|---|---|---|
| WAVE PCM | int16/24/32 LE, float32/64 LE | 8k–192k (12 standard) | 1–8 | 5 × 96 | bit-exact |
| AIFF PCM | int16/24/32 BE | 12 standard | 1–8 | 3 × 96 | bit-exact |
| AIFC PCM | int16/24/32 BE, float32/64 BE | 12 standard | 1–8 | 5 × 96 | bit-exact |
| CAF PCM | int16/24/32 LE, float32/64 LE, int16/24 BE, float32 BE | 12 standard | 1–8 | 8 × 96 | bit-exact |
| M4A ALAC, CAF ALAC | lossless 16/20/24/32 | 12 standard | 1, 2, 6, 8 | 2 × 4 × 48 | bit-exact, priming 0 |
| FLAC | lossless 16/24 | 12 standard | 1, 2, 6, 8 | 2 × 48 | bit-exact, priming 0 |
| M4A AAC, CAF AAC | lossy | 8k–48k (8) | 1, 2, 6, 8 | 2 × 32 | lag 0, corr ≥ 0.975, priming 2112 |
| CAF Opus | lossy | 8k / 16k / 24k / 48k | 1, 2 | 8 | lag ≤ 1 (24 kHz), corr ≥ 0.637, priming 52–312 |

**Planted failures (all typed, all with no sink made or the sink abandoned, security scopes balanced, source untouched).**
- Truncation at 5 / 60 / 97 % in 11 container/codec pairs → `truncated` / `missingAudioData`.
- Zero-length file → `emptyFile`, refused before open.
- Random bytes or text under 7 extensions, and a damaged header → `unreadableContainer`.
- Wrong extension → decodes as what the file actually is, with the mismatch recorded.
- Outside the envelope → `unsupported` with its reason: µ-law, IMA4, 8-bit, 12 345 Hz, 9-channel WAVE, 3-channel ALAC, and similar.
- Streaming WAVE size (0xFFFFFFFF) → `unsupported(unverifiableContainerLength)`.
- Missing, unreadable, directory or symlink source, unknown or not-downloaded residency → typed refusal before content opens; swapped file → `sourceIdentityMismatch`.
- Mid-decode change to the file or descriptor → `sourceChangedDuringDecode`.
- Read error, short or over-long stream, sink refusal or cancellation at any point → nothing published, reader closed.
- A writable descriptor (injected `O_RDWR` / `O_WRONLY` open) → `notOpenedReadOnly` before any read; the gateway checks `fcntl(F_GETFL)`.
- Every content read, including header and container-length reads, runs with dataless materialization off. This was observed per read for WAVE, AIFF, CAF, M4A AAC and M4A ALAC.
- "Source untouched" means equal SHA-256, size, mtime, ctime, inode, mode, `st_flags`, and every extended attribute (name and value).

28 source mutations, plus 13 more on the review hardening (gateway, scan, snapshot), were each caught by a failing test or a crash (see the PR).

**Not claimed (unevidenced, refused as `unsupported`).**
- Codecs and containers: MP3 (no native encoder), ADTS/raw AAC, RF64/W64/BWF extensions, µ-law/A-law/IMA4, 8-bit and packed 20-bit PCM.
- Rate and channel limits: AAC above 48 kHz or at 3/4/5/7 channels; Opus above 2 channels or at 12 k / 32 k+ rates; any rate not listed.
- Payload corruption that the codec accepts (PCM/AAC/ALAC bit flips decode silently).
- Lossy fidelity beyond landmark position.
- Channel layouts the writer did not declare (M4A stereo ALAC stores none).
- Dataless/iCloud materialisation against a real file provider.
- SRC (WW-018), time maps (WW-015), real recordings and the frozen holdout (later WW-050 units).

## WW-050 part 2: output-settings policy and `m2-freeze-decode` (calibration only)

Refs #45. Host: Apple M5 Max, 18 cores, 128 GiB, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4, debug build.

**Output-settings policy.** `OutputSettingsPolicy` (WWDecode, pure, `version` 1) takes the `FormatInterpretation`s of a
group or episode. It returns one common output rate, one sample format and one output channel per source channel
(no downmix or upmix), plus the ordered reasons for each choice. Defaults: the configurable 48 kHz and 24-bit integer
PCM.
- A rate is feasible when it is on the standard-rate grid and no source needs more than 64 source frames per output
  frame.
- When 48 kHz is infeasible, or the user chooses `.matchSources`, the rate is the most common feasible source rate
  (ties go to the higher rate). The highest source rate is always feasible.
- Stale interpretation versions, non-envelope rates and conflicting duplicates are refused with typed errors.

Each decision records its basis: the policy version, the configuration, and per-input interpretation and envelope
version, fingerprint, rate, format and channel count. `invalidations(for:configuration:)` names every change:
policy version, configuration, input added, dropped, changed or reordered, and a source listed twice with unequal
interpretations (`conflictingInputs`, which `decide` refuses). `OutputSettingsPolicyTests` covers mixed
rates, bit depths and channel counts, the refusals and the invalidations (14 tests). Eight policy mutants were each
killed (see the PR).

**Freeze.** [`m2-freeze-decode.json`](../fixtures/m2-freeze-decode.json) (2026-10-06, in the
[registry](../fixtures/m2-fixture-registry.json)) freezes fixture M2-DECODE-001 with:
- 13 strata: priming/padding per codec, decoded-frame origin, variable-rate, bit-depth/channel metadata, and
  truncated/corrupt/unsupported/changed sources;
- seeds `SHA-256("ww-m2-fixture|v1|M2-DECODE-001|<split>|<index>")`;
- 130 calibration and 520 holdout cases. Rule of three: zero failures in the holdout bounds the per-case failure rate
  below about 0.58 % overall and 7.5 % per stratum;
- the gate verbatim. 100 % of supported truth cases mapped correctly. Landmarks within 1 output frame. Every planted
  bad case is an explicit typed error, with no mutation (`FileSnapshot` equality) and no stale publication;
- the pinned `WWDecode` / `WWDecodeTests` tree IDs, which `DecodeFreezeTests` re-checks on every run.

**Calibration (pre-freeze), every gate PASS.** Records:
[`ww-050/calibration.jsonl`](ww-050/calibration.jsonl), SHA-256 `f2617e4b…3b01d07f38`, byte-identical across separate
processes.
- 90 supported cases (2,173,299 frames) mapped with 0 failures; 48 of them were bit-exact.
- 1,221 landmark observations: |lag| 0 ×1,197 and 1 ×24.
- Opus: 60 landmark observations; all 24 at 24 kHz are lag +1 (systematic, 24/24, priming 156), all 36 at 8/16/48 kHz
  are lag 0. Every 24 kHz Opus holdout landmark is expected at the 1-frame limit.
- Minimum correlation: lossy 0.669, exact 0.9999995.
- All 40 planted cases returned the expected error, with 0 mutations and 0 publications.
- Priming observed: AAC 2112, Opus 52/104/156/312 (rate/50 frames per packet), ALAC/FLAC/PCM 0.

Disclosed pre-freeze deviation: the first calibration run failed 3 bit-exact cases. The fixed ±3000-frame landmark search
had reached a neighbouring identical burst, so the window is now `min(3000, half-gap)`. No gate changed.
`scripts/test.sh` runs the calibration split in its own serialized pass. A split measures at most 4 cases at once (`WW_M2_FREEZE_MAX_CONCURRENCY` may lower it); the rerun under that cap gave byte-identical records.

## `m2-freeze-decode` holdout (frozen run)

**PASS — all gates.** This is the sole 520-case frozen holdout run. Before it started, the checkout was clean,
`HEAD` equalled `origin/main` at `7f17bfc417b52e5cc138be31cca4cd75632d24f0`, the 1-minute load was 7.19, and the
frozen trees matched: `Sources/WWDecode` `6f81db77162b493928798332f6d4ec9648f396d0`;
`Tests/WWDecodeTests` `383ebc0cfdc5515f78a33ad2a6dfaf3ea664e92b`; dependency trees also matched:
`Sources/WWSources` `fc8fb0fb661f318262d54d161baa3a04b475c792` and `Sources/WWCore`
`c310389c4b41ebde80c5dabaea12fd5376f5d9ba`. On the claimed Apple M5 Max host (macOS 27.0.1 (26A434),
Xcode 27.0 (27A266a), Swift 6.4, 18 cores, 128 GiB), it ran with the default maximum concurrency of four:

`cd Packages/WaveWranglerKit && WW_M2_DECODE_HOLDOUT=1 WW_DECODE_RECORDS_DIR=../../docs/m2/evidence/ww-050 swift test --scratch-path .build/swiftpm --filter DecodeCalibrationTests/holdoutSplitMeetsEveryFrozenGate`

The full raw output, including UTC start/end lines (2026-10-06T16:38:46Z through
2026-10-06T16:39:14Z), is [`ww-050/holdout-run.log`](ww-050/holdout-run.log). The per-case records are
[`ww-050/holdout.jsonl`](ww-050/holdout.jsonl); SHA-256s for both artifacts are in
[`ww-050/holdout.sha256`](ww-050/holdout.sha256).

- **Supported mapping: PASS.** All 360 supported cases mapped correctly, with 0 mapping failures and 0
  below-correlation landmarks. The mixed-input output-settings record also had 0 failures.
- **Landmarks: PASS.** 4,179 observations: `|lag| = 0` for 4,107 and `+1` for 72; no other lag occurred.
  All 72 `+1` observations were 24 kHz CAF Opus (30 from ten mono cases and 42 from seven stereo cases), the
  declared expected one-output-frame limit.
- **Planted typed errors and immutability: PASS.** All 160 planted cases returned their expected typed error;
  `FileSnapshot` mutations were 0 and stale publications (including finish, unabandoned output, open readers, or
  unbalanced scopes) were 0.

This is frozen holdout evidence, not calibration evidence.

## `m2-freeze-decode-2`: pull cursor freeze (calibration only)

Refs #45. The bounded `DecodingCursor` shares the push decoder's `ChunkPump`, gateway, envelope checks and
trimming. Owning-engineer review added a serial Dispatch worker so synchronous open/read/state/close calls do not
block Swift cooperative-executor threads, and added a post-read cancellation check so a chunk completed after
cancellation is discarded. The cursor retains one raw `channelCount × chunkFrames` buffer plus one returned chunk,
closes the reader and security scope on every path, treats failures as terminal, and returns no unverified result.
All source content still passes only through `SystemSourceContentIO`; its read-only descriptor and per-read
dataless-materialization policy are unchanged. The internal worker factory avoids the scanner-reserved `open(`
spelling so the always-on single-gateway enforcement remains green. Independent review then closed two
return-publication gaps: a terminal failure is rethrown even when the first read fails before the read counter
advances and the body catches it, and every result derived from reads receives a final unchanged-source check even
when the body explicitly checked earlier.

[`m2-freeze-decode-2.json`](../fixtures/m2-freeze-decode-2.json) supersedes revision 1 for the changed
`Sources/WWDecode` / `Tests/WWDecodeTests` trees while leaving the revision-1 record and its sole passed holdout
evidence unchanged. Revision 2 preserves the revision-1 recipe, truth, gate and counts verbatim, uses fixture
`M2-DECODE-002` so all 520 holdout seeds are disjoint from revision 1, and has its own
`WW_M2_DECODE_2_HOLDOUT` switch.

**Calibration PASS; holdout NOT RUN.** The serialized 130-case calibration ran five times at maximum concurrency
4 and produced byte-identical [`ww-050/calibration-2.jsonl`](ww-050/calibration-2.jsonl), SHA-256
`d9b58446340222a9f92b0e4ded8047a391b2be8f6bd94e16f4071c798951b356`. All gates passed: 90 supported
cases / 2,178,575 frames with 0 mapping failures; 1,014 landmarks (`lag 0` ×996, `lag +1` ×18, all +1 at
24 kHz Opus), 0 below correlation; 53 exact cases bit-exact; 40 planted cases with their expected typed errors,
0 mutations and 0 publications; output-settings failures 0. The always-on
`committedCalibrationRecordsReproduceTheReportedCalibration` test verifies the file SHA, seeds, counts, metrics and
all gate outcomes. The final calibration run used both pinned trees after the independent review fixes for
swallowed terminal failures and mandatory final source verification. No revision-2 holdout source was materialized
or decoded; it runs once in a separate PR after this freeze merges.
