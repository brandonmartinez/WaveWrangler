# WW-026: bounded in-process speech preparation

**Status: preparatory only.** Refs #23 #32. `WWSpeech` is compiled into the app through its local Swift package product. It has no content reader, model loader, recognizer dependency, network API or child/relay path. `SpeechInference.infer` checks the *current supplied canonical model* for exactly one user-confirmed Primary assignment, a known in-range channel and a confirmed Primary source, then **throws `engineUnavailable`**. Missing, provisional, ambiguous, Backup, or changed Primary assignments throw `unselectedPrimary`. This does not independently establish media identity or consent: no production media adapter exists, so no production inference or transcript is possible.

The Debug-only `--ww-speech-synthetic-probe` entry executes before AppKit creates a window. It invokes the linked package in the signed app executable, first refusing a synthetic Backup and production inference, then computes energy from four **generated** numbers. It reports only process ID, frame count, zero recognized words and Backup refusal. The package tests assert the same-process ID and refusal after Backup activation, provisional/unknown channel and ambiguous source. This is a **functional in-process synthetic seam**, not speech recognition, actual-model execution, runtime no-network proof, or a release capability. No recording, transcript or model was read, fetched, or posted.

## Candidate and rights boundary

The official [`whisper.cpp` README](https://github.com/ggml-org/whisper.cpp/blob/master/README.md) documents a C API and Apple Silicon CPU/Metal in-process library integration; its [source LICENSE](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE) and the separately used [ggml source LICENSE](https://github.com/ggml-org/ggml/blob/master/LICENSE) say MIT. The [OpenAI Whisper repository LICENSE](https://github.com/openai/whisper/blob/main/LICENSE) says MIT for its software. These **moving upstream documents are not a pinned source build, complete transitive audit, or an exact model-artifact license**. The `whisper.cpp` [model inventory](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md) lists converted weights with SHA-1 identifiers; no exact model license, origin/checksum chain, SHA-256, supported architecture or compiler/link flags has been verified for this app. No engine dependency or model body is added/downloaded by this change. Apple Speech cannot be assumed to infer inside this sandbox; it is not used.

## Observed checks and unproven acceptance

On the working Mac (macOS 27 / Xcode 27), the seven focused synthetic package cases and the 12 recursive source-content gateway checks passed without skips; Debug and Release app builds succeeded. `codesign --verify --deep --strict` succeeded on the ad-hoc signed builds, whose effective entitlements contained app-sandbox and **neither** network-client nor network-server. Direct headless execution of the signed Debug executable printed `WW_SPEECH_SYNTHETIC_IN_APP` with its own PID, four synthetic frames, zero words and `backup=refused`. The Release binary does not include the Debug probe argument. These checks were made on the branch's working tree, **not** a clean pushed exact-head acceptance run.

**STOP before product or offline acceptance:** pin and review the precise in-process engine source, license/notices, compiler/link configuration, every transitive and exact model artifact's rights and SHA-256; add a trusted selected-Primary-only decode/occurrence/revision adapter; prove actual model execution inside the signed sandboxed app. Then run the in-app endpoint-establishing TCP/UDP/raw denial matrix with EPERM/EACCES **and correlated sandbox violation logs**, startup/inference FD inventories excluding AF_INET/AF_INET6 and ingress, effective entitlements, static no-launcher/no-relay audit and fully offline measured inference. A denied loopback bind alone (the earlier #369 diagnostic) is not this matrix. Until these gates pass, do not analyze even approved real media; keep #23 and #32 open, and do not claim an M3 exit.

## Isolated caller-supplied PCM adapter (subsequent preparation)

`WWSpeech.BoundedPCMInference` adds a synchronous in-process native path for
**exactly 32,000 already-decoded finite mono Float samples at 16 kHz**. It takes
a `VerifiedTinyModel`, loaded with the same pinned size, SHA-256 and
nonmaterializing local-descriptor verification as the generated-PCM probe;
the probe reuses that loader without changing its `wordCount` or plain-text CLI.
The candidate is `ggml-tiny.en.bin` from the official `ggerganov/whisper.cpp`
Hugging Face revision `5359861c739e955e79d9a303bcbc70fb988958b1`:
77,704,715 bytes and SHA-256
`921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f`.
The pin alone does not establish installed bytes, redistribution rights or
an accepted derivation chain.
The native call uses two CPU threads, a two-second window and a 16-token /
16-segment result cap, suppresses upstream diagnostics, checks cancellation and
copies bounded segment text into memory. Only valid bounded segment intervals
are surfaced; unsupported intervals are nil. There are no word boundaries,
confidence values, file output or transcript logs. Ordinary unit tests use
synthetic PCM and incorrect model bytes; a model-backed sine-wave test is
opt-in via `WW_TINY_MODEL_PATH`, not a passing gate when skipped. After explicit
authorization on 2026-10-09, the exact revision-qualified body was downloaded
once to private non-synced storage outside Git on the working Mac; independent
local file checks observed 77,704,715 bytes and the full SHA-256 above before
use. On the clean pushed adapter code head `1ca7bb8e`, the generated-PCM
model-backed focused run passed **4/4** bounded-adapter tests and **6/6**
existing tiny-probe tests, with **zero skips** (`--jobs 2`, one test worker).
This is a local synthetic run, not a physical-Mini RTF/peak-memory measurement
or a signed sandboxed app inference/offline proof. No media was opened.

**Integration remains disabled:** `SpeechInference.infer` and `AppSpeech.infer`
still refuse `engineUnavailable`. `RecordedIdentity.rawWitness`, ordinary
decoding and package-internal witness opens are not selected-Primary authority.
This lower-level method cannot establish which source produced PCM, the
user-confirmed Primary, current same-descriptor witness, source-frame mapping,
consent or result currency. Production requires a separate sealed issuer
before any decoded media can enter it; Backup must never be opened in M3.
Model-artifact redistribution/derivation rights, signed-app in-process
endpoint/FD proof and measured offline inference are still unqualified. No word-level
producer or #21 frozen boundary/proposal evidence exists. These are STOP
gates, not acceptance for #23, #32, #41 or M3.
