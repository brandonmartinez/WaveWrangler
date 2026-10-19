# Local Whisper model choices

WaveWrangler offers Base English, Small English, Turbo and full Large-v3 through
the same offline whisper.cpp 1.6.2 adapter. Turbo remains the recommended default.
Small English and Large-v3 are additional resource/size choices, not a claim of
better accuracy, filler retention or word timing. The full Large-v3 architecture
uses Q5_0 quantization; "full" means non-Turbo, not full-precision weights.
Higher-precision Turbo is not offered.

## Immutable artifact provenance

All four download URLs resolve the MIT-licensed `ggerganov/whisper.cpp` repository
at commit [`5359861c739e955e79d9a303bcbc70fb988958b1`](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1),
not mutable `main`. Its [model card](https://huggingface.co/ggerganov/whisper.cpp/raw/5359861c739e955e79d9a303bcbc70fb988958b1/README.md)
identifies OpenAI Whisper models converted to GGML and declares MIT licensing.
SHA-256 and sizes come from the Git LFS pointers at that exact commit, not the
model card's shorter legacy SHA column and not a digest calculated from an
unverified mutable download.

| Choice | Artifact | Bytes | SHA-256 |
|---|---|---:|---|
| Base English (unchanged F16) | `ggml-base.en.bin` | 147,964,211 | `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002` |
| Small English (F16) | `ggml-small.en.bin` | 487,614,201 | `c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d` |
| Turbo (unchanged Q5_0) | `ggml-large-v3-turbo-q5_0.bin` | 574,041,195 | `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` |
| Full Large-v3 (Q5_0) | `ggml-large-v3-q5_0.bin` | 1,081,140,203 | `d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1` |

The two new pointers can be independently inspected at
[`ggml-small.en.bin`](https://huggingface.co/ggerganov/whisper.cpp/raw/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.en.bin)
and
[`ggml-large-v3-q5_0.bin`](https://huggingface.co/ggerganov/whisper.cpp/raw/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-q5_0.bin).
Both downloaded bodies were checked against these pre-established sizes and
SHA-256 digests before native qualification.

Selecting a model never downloads it. Explicit managed downloads retain
progress, cancellation, staging, verification and atomic installation. The
verified files can then be reused offline. Swift checks exact size and SHA-256
before every load; the native adapter additionally accepts only the four exact
artifact sizes. No inference input is sent over the network.

## Admission and compatibility

Each worker reserves 768 MiB for Base English, 2 GiB for Small English, 3 GiB for
Turbo, or 5 GiB for Large-v3, plus the source's existing multichannel render
envelope. These conservative reservations include retained verified bytes,
native weights/graphs and resampling buffers; they are not measured OS-memory
caps. Download verification instead reserves twice the artifact size while it
checks the downloaded body, through the same shared pool.

The app-wide budget remains one quarter of physical RAM (minimum 4 GiB, maximum
16 GiB), requested Whisper threads remain capped at `min(16, active CPU count)`,
and at most two Metal workers are admitted. The requested worker range remains
1-4. Large-v3 cannot fit the 4 GiB budget on a 16 GiB Mac; Settings warns about
this and transcription refuses before loading audio or weights. Smaller models
remain available without changing the system budget or silently substituting a
different model.

Model/audio loading stays inside admission. CPU, Metal and Automatic resolution,
30-second windows, English/disfluency decoding, source playback, timestamp
handling and human cut approval are unchanged. Existing `baseEnglish`/`turbo`
preference IDs, filenames, bytes, hashes and saved recipe revisions remain
unchanged. New recipes identify `smallEnglish` or `largeV3` and their exact digest;
changing settings does not rewrite saved transcripts or retarget captured jobs.

## Reproducing the focused native control

The pinned production adapter passed all four new model/backend combinations on
an M5 Max / 128 GiB, macOS 27.0.1 (26A434), Swift 6.4. The generated Samantha
control is 2.798271 seconds, mono Float32 48 kHz, SHA-256
`d6e74d745366bfac69c10afb864e41cbe0b9d4e6f322e9c6c633ba5e8aa3a4bd`.
Only the two new model bodies were downloaded for this qualification.

| Artifact | Backend | Control | Peak process RSS (bytes) |
|---|---|---|---:|
| Small English F16 | CPU / 2 threads | Pass | 1,555,251,200 |
| Small English F16 | Metal / 2 threads | Pass | 1,195,589,632 |
| Large-v3 Q5_0 | CPU / 2 threads | Pass | 3,863,822,336 |
| Large-v3 Q5_0 | Metal / 2 threads | Pass | 2,765,455,360 |

The process peaks (`/usr/bin/time -l` around individual `swift test --skip-build`
runs) support keeping headroom in the 2/5 GiB reservations. They do not establish
worst-case memory, account separately for all GPU/system allocations, or certify
smaller devices. The control checks "review", "meeting" and "notes"; both Small
English paths recognized the final "lunch" as "launch", while both Large-v3 paths
recognized "lunch". One short generated sentence is not an accuracy comparison.

Use only downloaded artifacts verified against the table and generated/local
licensed audio. The opt-in test never downloads anything. With a directory
containing the chosen exact model filename:

```sh
say -v Samantha -r 145 -o "$CONTROL/generated-control.aiff" \
  'We should review the meeting notes before lunch.'
afconvert -f WAVE -d LEF32@48000 -c 1 \
  "$CONTROL/generated-control.aiff" "$CONTROL/generated-control.wav"

SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
WW_WHISPER_QUALIFICATION_DIRECTORY="$CONTROL" \
WW_WHISPER_QUALIFICATION_MODEL=smallEnglish \
WW_WHISPER_QUALIFICATION_BACKEND=cpu \
swift test --package-path Packages/WaveWranglerKit --scratch-path .build/swiftpm \
  -c release -Xswiftc -DDEBUG --jobs 2 --no-parallel \
  --filter LocalWhisperTests.optedInGeneratedSpeechQualifiesPinnedModelAndBackend
```

Repeat serially with `largeV3` and `metal`; explicit Metal must be supported and
must not fall back to CPU. `automatic` may also be supplied to exercise resolution.
The production adapter loads inside shared admission and resamples the 48 kHz
control, checks recognizable words and bounded approximate timestamps, rejects
oversized input, handles preflight cancellation and bypasses exact digital zero.

These are format/backend compatibility controls, not a conversational corpus,
multilingual qualification, minimum-device certification, concurrency benchmark
or accuracy comparison. The earlier Base/Turbo comparisons remain historical
two-model controls and are not silently expanded to require new corpus artifacts.
Word times remain approximate and every model can hallucinate. No decoder or
timing policy changed and no automatic cuts were introduced.

## Regression verification

The focused Release package pass (with `-DDEBUG`, two build jobs and serial test
execution) reports 57 tests in nine `WWSpeechTests` suites passing. Existing
opt-in media/corpus controls remain skipped unless their own inputs are supplied;
the four new generated-speech native controls above ran separately.

The isolated Debug app/hosted build also passed. `TranscriptionSettingsTests`
reports 14 passing test functions / 23 expanded runs, zero failures and one
intentionally skipped existing opt-in signed-app native control. Parameterized
coverage checks all four preferences, managed installation/replacement,
availability across settings instances, and actual size/hash rejection. Existing
tests retain default Turbo, legacy bookmarks, shared workers, cancellation,
transport failure and captured-hardware behavior.

Hosted execution used `scripts/gui-lock run` around `xcodebuild
test-without-building`, after a separate `build-for-testing` and a live check that
the editing app was closed. The result is
`.build/WhisperModelHosted/TranscriptionSettings.xcresult`. The lease was released
and no app/hosted process remained. No normal editing-app launch or private audio
access occurred. New weights were qualified in the package's real CPU/Metal
adapter, not requalified inside the signed app bundle; no broad UI, full
repository/DSP suite or minimum-memory-device qualification is claimed.
