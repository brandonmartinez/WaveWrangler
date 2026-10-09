# WW-026: bounded in-process speech preparation

**Status: preparatory only.** Refs #23 #32. The initial preparation below predates the isolated adapter documented at the end. `WWSpeech` is compiled into the app through its local Swift package product. Its production path has no content reader, model loader, recognizer invocation, network API or child/relay path. `SpeechInference.infer` checks the *current supplied canonical model* for exactly one user-confirmed Primary assignment, a known in-range channel and a confirmed Primary source, then **throws `engineUnavailable`**. Missing, provisional, ambiguous, Backup, or changed Primary assignments throw `unselectedPrimary`. This does not independently establish media identity or consent: no production media adapter exists, so no production inference or transcript is possible.

The Debug-only `--ww-speech-synthetic-probe` entry executes before AppKit creates a window. It invokes the linked package in the signed app executable, first refusing a synthetic Backup and production inference, then computes energy from four **generated** numbers. It reports only process ID, frame count, zero recognized words and Backup refusal. The package tests assert the same-process ID and refusal after Backup activation, provisional/unknown channel and ambiguous source. This is a **functional in-process synthetic seam**, not speech recognition, actual-model execution, runtime no-network proof, or a release capability. No recording, transcript or model was read, fetched, or posted.

## Candidate and rights boundary

The official [`whisper.cpp` README](https://github.com/ggml-org/whisper.cpp/blob/master/README.md) documents a C API and Apple Silicon CPU/Metal in-process library integration; its [source LICENSE](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE) and the separately used [ggml source LICENSE](https://github.com/ggml-org/ggml/blob/master/LICENSE) say MIT. The [OpenAI Whisper repository LICENSE](https://github.com/openai/whisper/blob/main/LICENSE) says MIT for its software. These **moving upstream documents are not a pinned source build, complete transitive audit, or an exact model-artifact license**. The `whisper.cpp` [model inventory](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md) lists converted weights with SHA-1 identifiers; no exact model license, origin/checksum chain, SHA-256, supported architecture or compiler/link flags has been verified for this app. No engine dependency or model body is added/downloaded by this change. Apple Speech cannot be assumed to infer inside this sandbox; it is not used.

## Observed checks and unproven acceptance

On the working Mac (macOS 27 / Xcode 27), the seven focused synthetic package cases and the 12 recursive source-content gateway checks passed without skips; Debug and Release app builds succeeded. `codesign --verify --deep --strict` succeeded on the ad-hoc signed builds, whose effective entitlements contained app-sandbox and **neither** network-client nor network-server. Direct headless execution of the signed Debug executable printed `WW_SPEECH_SYNTHETIC_IN_APP` with its own PID, four synthetic frames, zero words and `backup=refused`. The Release binary does not include the Debug probe argument. These checks were made on the branch's working tree, **not** a clean pushed exact-head acceptance run.

**STOP before product or offline acceptance:** pin and review the precise in-process engine source, license/notices, compiler/link configuration, every transitive and exact model artifact's rights and SHA-256; add a trusted selected-Primary-only decode/occurrence/revision adapter; prove actual model execution inside the signed sandboxed app. Then run the in-app endpoint-establishing TCP/UDP/raw denial matrix with EPERM/EACCES **and correlated sandbox violation logs**, startup/inference FD inventories excluding AF_INET/AF_INET6 and ingress, effective entitlements, static no-launcher/no-relay audit and fully offline measured inference. A denied loopback bind alone (the earlier #369 diagnostic) is not this matrix. Until these gates pass, do not analyze even approved real media; keep #23 and #32 open, and do not claim an M3 exit.

## Isolated caller-supplied PCM adapter (subsequent preparation)

`WWSpeech.BoundedPCMInference` now has a separate, synchronous, in-process native
path for **exactly 32,000 already-decoded finite mono Float samples at 16 kHz**.
It takes a `VerifiedTinyModel`, loaded using the same pinned size, SHA-256 and
nonmaterializing local-descriptor verification as the generated-PCM probe;
the probe reuses that loader. Its native call uses two CPU threads, a two-second
window and a 16-token / 16-segment result cap, suppresses upstream diagnostics,
checks cancellation and copies segment text into an in-memory typed result.
Only valid bounded segment intervals are surfaced; missing intervals are nil.
There is no word-timing, word-confidence, file-output or transcript logging path.
The opt-in model-backed unit test generates a sine wave and is disabled without
`WW_TINY_MODEL_PATH`; ordinary tests use synthetic invalid buffers and assets.

**Integration remains disabled:** `SpeechInference.infer` and `AppSpeech.infer`
still refuse `engineUnavailable` after selected-Primary checks. This lower-level
method does **not** verify which recording produced a PCM buffer, a user's
selected Primary, source fingerprint, format/occurrence/primary revision, consent,
or result currency; it must not be wired to the app or used on approved media yet.
Exact model-artifact rights and provisioning are not qualified. The signed app's
in-process sandbox endpoint/FD proof and measured offline inference remain unrun.
No word-level producer, source-frame mapping, stale invalidation or #21 frozen
1000-boundary / 300-proposal evidence is provided. These are explicit STOP gates,
not acceptance evidence for #23, #32, #41 or M3.

## Third synthetic probe pass: experimental DTW preparation

The separate `ww-tiny-pcm-probe` can explicitly request
`--experimental-dtw tiny.en` with its existing `--model` descriptor. The
verified local tiny.en loader refuses absent/mismatched model descriptors and
the opt-in refuses absent/mismatched preset strings before reading model
content. The native bridge accepts only the exact tiny.en alignment-head
preset; it runs the two preexisting non-DTW passes first, then (only on
successful opt-in) initializes a new CPU context and runs pinned v1.6.2
experimental DTW over the same generated two-second tone. An unsuccessful
third pass refuses the probe. Output is aggregate-only with separate DTW
load/inference duration and present/absent **token point** counts, not DTW
intervals, validated words or confidence; `wordTimingAvailable=false` and
`supportedWordBoundaryCount=0` always. See
[WW-027's characterization](../ww-027-word-proposal-freeze.md) for the
field classification and unchanged holdout STOP.

This does not alter `BoundedPCMInference`, `SpeechInference.infer`, or any
selected-Primary admission path. Source/diff checks only are permitted while
host capacity is held by other gates; no compiler, model-backed run, app
sandbox network/FD proof, rights chain or approved-media evidence is
established here. #23, #32 and #21 remain open.
