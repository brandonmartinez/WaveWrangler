# Next-session prompt: Apple Silicon transcription acceleration

Copy the following prompt into a new, independent, top-level WaveWrangler session after
squash-merging the transcription/Cleanup work into local `main`. Do not create another session
automatically.

---

Research, benchmark, and then implement appropriate Apple Silicon hardware acceleration for
WaveWrangler's local Whisper transcription. The goal is a reliable app-wide choice of CPU,
GPU/Metal, Neural Engine/Core ML, or a sensible combined/Automatic mode, with bounded,
user-selectable parallelism. Do not promise that every hardware combination is supported or faster.

## Starting point

- Start from the newly squash-merged **local** `main`; verify that the Cleanup timeline,
  `TranscriptionSettings`, and `TranscriptionWorkerPool` are present. Local main may be ahead of
  origin. Work only in this session's isolated worktree, not the original checkout.
- The machine used so far is an Apple M5 Max with 128 GiB RAM. Verify actual hardware, OS, SDK and
  available model/tool versions rather than assuming these remain unchanged.
- Production inference is the vendored **whisper.cpp 1.6.2 CPU/Accelerate** backend, with a local
  token-timestamp bounds correction. Metal and Core ML are **not** compiled/enabled. Each worker
  requests four Whisper threads; Accelerate may use additional internal execution resources.
- Settings offers pinned, verified Base English and Turbo Q5_0 models, explicit downloads with
  progress/cancel/integrity checks, and **1-4 concurrent transcription workers** (default 1).
  One worker handles one Primary speaker with sequential bounded chunks. One cancellable global
  pool is shared across episode windows; these are in-process workers, not OS processes.
- Independent native contexts now infer concurrently. Context initialization alone is serialized
  for shared upstream FFT/backend initialization; logging is configured once. Actual 2/4-worker
  Base and Turbo runs on the licensed public control preserved serial text and timestamps.
  Those checks prove overlap/equivalence, **not** optimal throughput or safe limits on every Mac.
- `docs/research/transcription-engine-comparison.md` contains earlier accuracy research. Its
  whisper.cpp 1.9.4/Metal results are **not** production CPU-backend measurements.

## Research and bounded measurements first

1. Inspect the actual app/backend interfaces and primary upstream sources. Compare a compatible
   whisper.cpp Metal path, its Core ML encoder path, and alternatives such as WhisperKit only
   where justified. Determine model formats, conversion/download requirements, licenses,
   sandbox/signing implications, cancellation, timestamp support, and offline feasibility.
   Avoid private or unsupported ANE APIs. Do not assume the older backend has current capabilities.
2. Distinguish full-model GPU execution from an ANE encoder plus CPU/GPU decoder. Core ML compute
   units permit devices; they do not prove every operation runs on the ANE. Investigate actual
   placement/fallback and explain it truthfully in the UI. Unsupported hardware must have explicit
   availability/recovery states, not silently masquerade as the requested backend.
3. Run reproducible, bounded comparisons on the **same licensed public speech and genuine
   references**, including conversational fillers/disfluencies, overlap, pauses and silence.
   Use existing public fixtures where possible. Compare CPU baseline, GPU and viable Core ML
   combinations at 1, 2 and, only where resource-safe, higher worker counts.
4. Keep prompt, language, normalization, chunk/core ownership and decoding settings comparable;
   disclose unavoidable differences in model/quantization or algorithms. Measure WER, filler
   retention, hallucinations, approximate timing, cold/warm latency, throughput, peak memory and
   cancellation/responsiveness. Separate encoder-only acceleration claims from end-to-end results.
   Do not infer cut-boundary quality from WER or invent unavailable measurements.
5. Record actual supported paths, bottlenecks and measured recommendations before selecting the
   simplest implementation. Keep CPU as a fallback. If a backend is unsuitable, report evidence
   rather than adding a nonfunctional selector.

## Implementation and safety requirements

- Keep model/backend and resource controls in **Settings > Transcription**, shared across episodes.
  Prefer clear choices such as Automatic, CPU, CPU + GPU, or CPU + Neural Engine when those labels
  reflect real execution. A pure "Neural" label must not imply unsupported all-ANE execution.
- Offer sensible maximum parallel-worker and CPU-thread/resource controls where applicable.
  Enforce **one app-wide budget**, including across simultaneous episode windows. Profile before
  choosing defaults/caps: several CPU workers do not imply the same optimum for a shared GPU/ANE.
  Account for model loading/retention as well as inference working memory and render buffers.
  Show queued versus active work and meaningful aggregate progress.
- Capture model/backend/recipe for the job and saved transcript. Define changes during active jobs
  and lowering limits explicitly. No hidden model download, filesystem model picking requirement,
  backend substitution or configuration-induced cancellation. Preserve explicit consented downloads,
  hash/size verification, atomic installation, cancellation/retry and offline reuse.
- Require **all** current Primaries to be aligned before transcription. Preserve accepted affine
  and adaptive timing, exact 48 kHz bounded rendering, original source-frame anchors, source identity,
  alignment revision and analyzed In/Out range. Hardware acceleration must not retime originals,
  reinterpret timing gaps, change export policy, or silently move saved words.
- Preserve raw disfluent recognition and review-only uncertainty markers. Timestamps remain
  approximate, not automatic cut authority. Do not add filler/silence cuts or VAD-based text deletion.
- Reverify every source/map and publish all speaker results atomically in deterministic order.
  Cancellation, failure, source replacement, stale document/configuration or changed timing must
  publish no partial transcript. Drain workers and release all resources on every path.
- Use fake-engine and actual native tests to prove overlap, global ceilings, deterministic mapping,
  out-of-order progress handling, cancellation, error propagation, and fallback/unsupported-device
  behavior. Update native integrity pins and recipe identifiers if the vendored engine changes.
- Private episode recordings were **not** authorized for agent-run transcription or upload.
  Do not inspect/transcribe them or upload any recording, transcript or private code to a service.
  Use generated/licensed public fixtures; ask for exact consent if private samples are necessary.
  Document any additional public model downloads, their provenance, size and integrity.
- Source `$HOME/.shell/exports-core.sh` in every shell call before user-installed tools. Preserve
  existing language/package configuration and registries. Use established commands and coordinated
  worker counts; do not install dependencies before a manifest change or missing-tool failure.
- Never overwrite a running app's signed bundle. Keep normal app builds in `.build/AppDerivedData`
  and tests in `.build/DerivedData`. Ask the user to save/quit before app-hosted or UI testing.
  Do not change macOS permissions to work around stale signatures.

Deliver working, verified integration when feasible, concise measured findings with primary
citations and limitations, and accurate Settings documentation. Do not push, create a PR, or merge
unless separately requested.

Useful starting sources:

- https://github.com/ggml-org/whisper.cpp#core-ml-support
- https://github.com/argmaxinc/argmax-oss-swift
- https://developer.apple.com/documentation/coreml/mlcomputeunits
- `WaveWrangler/Alignment/AlignmentRuntime.swift`
- `Packages/WaveWranglerKit/Sources/WWSpeech/LocalWhisper.swift`
- `Packages/WaveWranglerKit/Sources/WWSpeech/TranscriptionWorkerPool.swift`
- `Packages/WaveWranglerKit/Sources/WWWhisperNative/CPUBridge.c`
- `WaveWrangler/Settings/TranscriptionSettings.swift`
- `WaveWrangler/Cleanup/CleanupTranscriptionProgress.swift`
- `WaveWranglerHostedTests/CleanupTranscriptionTimingTests.swift`
