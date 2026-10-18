# Apple Silicon transcription: measurements and integration

Measured 2026-10-18 UTC: Mac Studio, Apple M5 Max (18 CPU / 40 GPU cores),
128 GiB unified memory, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
Started from local `05c63e8`, sole parent `7b1ad2d`, with a tree identical to
the previously verified `611b6e5`. No private episode audio was used.

## Decision and actual production-adapter results

Ship the existing pinned weights with **CPU / Accelerate**, **CPU + GPU / Metal**,
and **Automatic**. Automatic resolves once to Metal on a supported Apple GPU
(Apple family 7 or newer), otherwise CPU. The native bridge checks the actual
model and state backends. Failed initialization or CPU fallback stops with
choose-CPU-and-retry recovery, never CPU inference mislabeled as GPU.
Encoder/decoder tensor inference can use Metal; audio preparation, sampling
control and other host work still use the CPU. No all-GPU execution is claimed.

The final **actual `LocalWhisper` adapter**, not only a research runner, was
exercised on all six public speech clips plus digital zero. Input was expanded
from 16 to 48 kHz by sample repetition, then passed through production resampling,
token filtering and zero handling. This is a reproducible resampling control,
not every accepted aligned renderer. Optimized package/native code, four
requested threads, one worker, two rounds:

| Weights / backend | First / warm seconds | Strict WER | Exact reference `um`/`uh` retained |
| --- | ---: | ---: | ---: |
| Base / CPU | 4.843 / 4.831 | 13.73% (S27 D8 I4) | 24/29 |
| Base / Metal | 1.930 / 1.932 | 13.73% (S27 D8 I4) | 24/29 |
| Turbo Q5_0 / CPU | 37.377 / 37.300 | 9.86% (S11 D6 I11) | 28/29 |
| Turbo Q5_0 / Metal | 4.466 / 4.436 | 9.15% (S10 D6 I10) | 28/29 |

Warm Metal was about **2.5x Base / 8.4x Turbo** in this adapter control,
with no measured filler-retention loss. These are small-corpus observations,
not universal quality/speed promises or full-episode/UI timings. Weight reading
and SHA verification were separately 0.056-0.058 s/Base and 0.216-0.220 s/Turbo.
Source reading/rendering and final document publication are excluded.
Production and raw-16-kHz candidate scores below are deliberately separate:
resampling/numerical differences changed some Turbo text. CPU/GPU timestamps
must not be assumed identical.

Keep **Core ML / Neural Engine deferred**, not a nonfunctional preference.
The viable experiment accelerates only the encoder, permits CPU + ANE, and
still needs a CPU or Metal decoder. It did not consistently beat Metal;
Turbo adds a 1.17 GB converted encoder download, specialization cost and
different numerical results. This is a tradeoff decision, not evidence that
the Mac cannot use its Neural Engine.

## Corpus, rights, scoring, and limitations

Same genuine references as the [earlier comparison](transcription-engine-comparison.md):
AMI ES2002a speaker B, headset channel 1, CC BY 4.0; attribution AMI Consortium /
University of Edinburgh. Source intervals in seconds:
`[55.73,67.55)`, `[92.48,102)`, `[108.71,132.20)`, `[142.66,165.91)`,
`[394.62,422.47)`, `[465.51,487.21)`.
Six clips: **117.63 s, 284 normalized reference words, 29 exact `um`/`uh`**;
plus 10 s generated digital zero, total 127.63 s. Disfluencies, pauses and
one other-speaker backchannel are included. This is limited overlap coverage
from one meeting/channel, not a diverse podcast holdout.

Manual word text is genuine. AMI word times are automatically forced-aligned,
**not human-validated cut boundaries**. Scores use the existing normalized
Levenshtein alignment and exact filler matching, not cleaned-up prose.
Actual-adapter timing proxy: 426 matched boundaries/Base, p95 2.08 s;
524 CPU / 526 Metal boundaries/Turbo, p95 1.55 s.
Raw-candidate proxy: Base CPU p95 2.79 s (444 boundaries), Base Metal/Core ML
2.45 s (430); Turbo CPU/Metal 1.36 s (526), CPU+ANE 1.42 s (528),
Metal+ANE 1.49 s (524). Samples differ with text and valid timestamps.
None establishes safe word cuts or authorizes automatic edits.

Both production backends emitted **zero words on exact digital zero** via
the pre-existing shortcut. The deliberately unfiltered raw-engine control
exposed Base's repetitive 111-word hallucination and Turbo's `You're welcome.`
(two words), on both CPU and Metal. General nonzero silence, noise and short
hallucinations remain unsolved. No VAD/text deletion was added; raw recognition
and review-only uncertainty are preserved.

The publisher endpoint refused connections this session. Named original
public inputs were recovered from the preceding research session, then
checked against the original manifest, not replaced with private audio:

| Input | SHA-256 |
| --- | --- |
| `ami_public_manual_1.6.2.zip` | `b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d` |
| `ES2002a.Headset-1.wav` | `285ed5b5eaa4f871cc146900d0cf87487ca757aa57a7062def2eb49feaabc23d` |

Source: [AMI Corpus](https://groups.inf.ed.ac.uk/ami/corpus/).
First native control `ami-01.wav` SHA-256:
`56f4b4abd278c61426b7ec4c844c5aff1420204a7b18ac7976321f8dc26c9b83`.
Audio, weights, manifest, raw outputs and logs remain outside Git in
session `8f95f235-c6a6-4be2-89f3-663b7ebcdade/files/asr`.

## Comparable raw-16-kHz worker matrix

The research executable uses vendored **1.6.2 plus token-bounds fix**, not
the older report's external 1.9.4 runner. Four requested threads; English;
beam/best-of 5; no context; token timestamps; max_len 1; split_on_word;
no temperature fallback; prompt:
`Um, uh, well, I, I mean, you know, like, sort of.`
CPU/Metal use identical weights/quantization.

Each round schedules seven bounded clips with a fresh context per clip.
Only initialization is serialized; inference overlaps. Candidate weights
are read once/shared. The app instead retains separately verified bytes
per admitted speaker lane, with a context per window. Matrix wall time
includes context setup/inference/free, not initial file/hash verification,
source rendering or publication. It compares backend throughput, not complete
episode duration.

| Weights / path | Workers | First / warm s | Warm peak process MiB |
| --- | ---: | ---: | ---: |
| Base CPU | 1 | 3.713 / 3.660 | 604 |
| Base CPU | 2 | 2.622 / 2.578 | 1,004 |
| Base CPU | 4 | 1.918 / 1.896 | 1,839 |
| Base Metal | 1 | 2.759 / 2.667 | 450 |
| Base Metal | 2 | 1.890 / 1.825 | 674 |
| Base Metal | 4 | 1.466 / 1.434 | 1,112 |
| Turbo CPU | 1 | 27.086 / 29.126 | 2,308 |
| Turbo CPU | 2 | 20.541 / 20.833 | 4,015 |
| Turbo CPU | 4 | 15.097 / 14.318 | 7,385 |
| Turbo Metal | 1 | 5.674 / 5.645 | 1,298 |
| Turbo Metal | 2 | 4.344 / 4.359 | 1,963 |
| Turbo Metal | 4 | 3.832 / 3.773 | 3,272 |
| Base CPU decoder + CPU/ANE encoder | 1 | 3.624 / 2.570 | 449 |
| Base CPU decoder + CPU/ANE encoder | 2 | 1.835 / 1.831 | 687 |
| Base Metal decoder + CPU/ANE encoder | 1 | 2.904 / 2.868 | 459 |
| Base Metal decoder + CPU/ANE encoder | 2 | 1.967 / 1.872 | 689 |
| Turbo CPU decoder + CPU/ANE encoder | 1 | 24.857 / 8.877 | 2,471 |
| Turbo CPU decoder + CPU/ANE encoder | 2 | 6.115 / 6.025 | 2,028 |
| Turbo Metal decoder + CPU/ANE encoder | 1 | 6.623 / 6.610 | 1,336 |
| Turbo Metal decoder + CPU/ANE encoder | 2 | 4.202 / 4.154 | 2,010 |

Peak RSS is a cumulative process high-water mark, **not complete GPU/ANE/
unified-system memory accounting**. First rounds are process-cold/cache-warm:
the earliest pre-matrix Metal run was 6.027 s, then 2.676 s warm, showing
shader compilation/cache cost. No OS/driver caches were purged. Turbo's first
Core ML specialization must not be described as an already warm encoder.

Raw Base WER/fillers: 13.73%, 24/29 on all measured paths. Turbo CPU/Metal:
8.45% (S11 D6 I7), 26/29 at all worker/thread counts. Turbo CPU+ANE:
7.39%, 27/29; Metal+ANE: 8.10%, 27/29. These small differences are not
established accuracy gains. Same-backend concurrent text/times were stable;
cross-backend equality is not an invariant.
Warm one-worker Turbo CPU/Metal processed this complete control at roughly
4.38x / 22.61x real time, two-worker Metal at 29.28x; raw zero is included
in these denominators, whereas production bypasses it.

## Threads, cancellation, and conservative limits

Warm one-worker Turbo seconds at 1 / 2 / 4 / 8 requested threads:
CPU **75.015 / 43.190 / 29.126 / 24.384**;
Metal **6.271 / 5.859 / 5.645 / 5.571**.
Keep default four and expose 1/2/4/8. Eight helped CPU modestly but Metal
only ~1%; requested Metal threads also affect command-buffer submission.
Accelerate/Metal can use additional threads: this is not an OS-thread cap.

Default **one** worker, user maximum **1-4**, with two worth trying on this
high-memory Mac. Cap simultaneously admitted **Metal workers at two**.
Four improved raw throughput another ~13% Turbo / ~21% Base over two, but
Turbo summed per-clip inference grew from 6.80 to 11.70 s (~72%), with more
memory and shared-GPU contention. This is a conservative interactive budget,
not a globally optimal concurrency claim.

The one app-wide pool, shared across episode windows and default download
verification, also caps requested Whisper threads at `min(16, active CPU count)`
and memory reservations at `clamp(physical RAM / 4, 4 GiB, 16 GiB)`.
Each speaker reserves **768 MiB/Base or 3 GiB/Turbo**, plus its actual
multichannel render envelope:
`channels * (sourceRate * 15 + 48000 * 6) * 4 * 8 + 32 MiB`.
This includes the existing adaptive renderer, resampling, verified weights
and native graphs, not merely mono PCM. Download verification reserves twice
the weight byte count in the same pool. Impossible requests fail before loading;
requests that fit alone queue FIFO. No speaker weights are retained while queued;
there is no idle model cache or nested model/inference admission deadlock.
Budgets bound admitted work, not every OS allocation or unrelated app usage.

Raw-candidate cancellation requested 50 ms into `whisper_full` drained Turbo
CPU in 3.272 s / Metal in 0.331 s (whole operation 3.326 / 0.443 s).
Do not promise instantaneous interruption inside a tensor operation.
The final optimized production test instead waited for a native graph
checkpoint, delayed 20 ms, then cancelled. Observed drain after that request:
Base CPU/Metal **3.4 / 6.8 ms**, Turbo CPU/Metal **9.7 / 16.4 ms**.
These are different cancellation points, not competing SLA measurements.
Initialization remains serialized/non-interruptible. An independent 20 ms
MainActor heartbeat during native qualification had maximum gaps ~30 ms
(Debug qualification <=39 ms). That proves executor responsiveness in this
control, not full editing/scrolling performance for all workloads.

## Why no Neural Engine selector yet

[whisper.cpp v1.6.2 Core ML](https://github.com/ggml-org/whisper.cpp/tree/v1.6.2/coreml)
replaces **only the encoder**, needs a sibling converted `.mlmodelc`, and
retains the ordinary CPU/GPU decoder. Stock code sets `MLComputeUnitsAll`;
the experiment used public `MLComputeUnitsCPUAndNeuralEngine`.
[Apple compute units](https://developer.apple.com/documentation/coreml/mlcomputeunits)
permit devices; they do not promise every operation executes there.

The public [MLComputePlan](https://developer.apple.com/documentation/coreml/mlcomputeplan-1w21n)
anticipated placement reported 153 Neural Engine / 234 unknown operations
for Base and 2,443 / 3,194 for Turbo. This is **not a runtime trace or
all-ANE proof**. No private ANE APIs or ANEForge were used.
Base CPU+ANE barely improved on Metal alone at one worker and matched it at
two; adding ANE to Metal was slower. Turbo Metal+ANE was slower at one worker
and only ~4.7% faster at two. Those gains do not yet justify extra converted
weight installation, specialization, cancellation and error-handling surfaces.
The old Core ML wrapper's prediction errors and pathname-based model loading
also need hardening before integrating with verified-byte admission.

[WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) is an alternative
Core ML pipeline, but needs different models/tokenization/decoding and its own
offline fallback/word-timing qualification. It was inspected, not benchmarked
or substituted. No WhisperKit inference result is claimed.

## Source, downloads, and reproduction

Compatible MIT-licensed [Metal sources](https://github.com/ggml-org/whisper.cpp/blob/v1.6.2/ggml-metal.m)
were added without upgrading the engine or removing its timestamp fix.
Original downloaded hashes:

| Source | SHA-256 |
| --- | --- |
| `ggml-metal.h` | `1262be1c24dea4e0f9bc6a904c4810c8129038d8f260b6773989ed7b0ed15dba` |
| `ggml-metal.m` | `428c6301eeb24a742bb37cd46e551e502cf3b5093bd5ef59a18f5bafa1b09f1f` |
| `ggml-metal.metal` | `1f4ba3c90b02ee0a3bca09e0806b5d32e582e0704e4fbdf0f9d00bf89ec83191` |

Local patches add actual-backend inspection, once-only logging, initialization
cleanup, autorelease pools and trusted SwiftPM shader resources. Public runtime
Metal compilation uses only bundled resources, not cwd/env overrides, an
external inference process or a network service. Upstream-style manual
Objective-C reference counting and `.copy` shader/header resources avoid a
standalone `metallib` compiler requirement. Existing bundled MIT/YaRN notices
are retained. The signed app's own resource bundle was exercised offline.

Current ordered 17-file pin:
`031897a71dcc8180aa64004a73c14e4032634a121fe235347c925a3f9378526d`,
enforced by `scripts/verify-whisper-native.sh`.
Recipe: `whisper.cpp/1.6.2+ww-token-bounds-v1+metal-v1/<model>/<sha>/verbatim-v1/`
`requested=<choice>;backend=<actual>;threads=<count>`.
Settings affect future jobs; lowering workers drains existing active work.
Loading, waiting, rendering, recognition and final verification remain visible.

Research models came from
[`ggerganov/whisper.cpp` revision `5359861c739e955e79d9a303bcbc70fb988958b1`](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1).
These are public artifact downloads, not private media or uploads:

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `ggml-base.en.bin` | 147,964,211 | `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002` |
| `ggml-large-v3-turbo-q5_0.bin` | 574,041,195 | `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` |
| `ggml-base.en-encoder.mlmodelc.zip` | 37,950,917 | `8cf860309e2449e2bdc8be834cf838ab2565747ecc8c0ef914ef5975115e192b` |
| `ggml-large-v3-turbo-encoder.mlmodelc.zip` | 1,173,393,014 | `84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a` |

Let external directory `R` contain `downloads/` with these verified inputs.
`scripts/asr-research/benchmark.py prepare --artifacts "$R"` creates the same
public crop manifest. Download the three original Metal files and
`coreml/{whisper-encoder.h,whisper-encoder.mm,whisper-encoder-impl.h,whisper-encoder-impl.m}`
from **v1.6.2** into `"$R/candidate"`, preserving `coreml/`. Extract encoders
beside their corresponding GGML models as upstream specifies. Then:

```bash
source "$HOME/.shell/exports-core.sh"
bash scripts/asr-research/build-acceleration.sh "$R/candidate"
GGML_METAL_PATH_RESOURCES="$R/candidate/runtime" python3 scripts/asr-research/acceleration.py \
  --artifacts "$R" --executable "$R/candidate/acceleration" \
  --model large-v3-turbo-q5_0 --backend metal --workers 2 --threads 4
```

Repeat CPU/Metal, Base/Turbo, 1/2/4 workers; use `acceleration-coreml` and
`--coreml` for encoder-only experiments (1/2 workers); `--cancel-ms 50` for
raw cancellation. `coreml-placement.swift MODEL.mlmodelc` prints the separately
qualified compute-plan output. The Python harness verifies model/crop hashes
and saves command, executable hash, raw segments, time, RSS and scores under
`"$R/acceleration"`.

Final actual-adapter qualification and complete corpus evidence:

```bash
WW_ASR_ACCELERATION_FIXTURES="$R" \
  swift test -c release -Xswiftc -DDEBUG --package-path Packages/WaveWranglerKit \
  --scratch-path .build/swiftpm --jobs 4 --filter 'LocalWhisperTests|TranscriptionResourceTests'
WW_ASR_ACCELERATION_FIXTURES="$R" WW_ASR_FULL_CORPUS=1 \
  swift test -c release -Xswiftc -DDEBUG --package-path Packages/WaveWranglerKit \
  --scratch-path .build/swiftpm --jobs 4 --filter optedInProductionCorpus
```

`-DDEBUG` retains an existing unrelated test hook needed to compile the entire
Release test graph; native inference remains optimized. The corpus test writes
`production-*.json`; score clips with
`acceleration.metrics(manifest["clips"], round["clips"])`.
Do not conflate these adapter results with raw-candidate outputs.

## Safety and verification

All-Primary readiness, accepted affine/adaptive mapping, exact half-open
48 kHz windows, source identity/frame anchors, review-only uncertainty,
working In/Out range, final revalidation, deterministic all-speaker publication
and undo remain intact. Hardware changes never retime sources or alter
cut/export policy. Failure/cancellation releases reservations and publishes
no partial transcript. No hidden download or preference-induced cancellation.

Package/hosted checks cover captured hardware/threads, unsupported-device
recovery, shared memory/thread/GPU ceilings, queued cancellation, release on
errors, loading only after admission, source/mapping/progress safety, and
existing installation behavior. Real Base/Turbo CPU/Metal contexts overlapped
two-way and preserved same-backend text/times. The signed host executed Metal
from its own resource bundle offline. A deliberately resource-less executable
refused Metal fallback (`backendUnavailable`), then succeeded on explicit CPU:

```bash
bash scripts/test-whisper-backend.sh "$R/downloads/ggml-base.en.bin"
bash scripts/test-verify-whisper-native.sh
bash scripts/test-whisper-timestamps.sh
```

The graphical Settings smoke test could not activate the app from its
background state in this macOS desktop session; it did not reach the controls.
No permissions were changed to bypass that limitation. Native and signed-host
checks are distinct from that uncompleted foreground interaction check.
