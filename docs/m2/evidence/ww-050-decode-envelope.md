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
