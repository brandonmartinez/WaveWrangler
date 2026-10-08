# WW-026 replacement: scoped local speech candidate

**2026-10-08; #23 remains PARTIAL.** This is a headless candidate, not app integration or
permission to infer from arbitrary files. `PrimarySpeechSelection` requires a unique,
user-confirmed primary channel. The future adapter still must obtain the PCM proxy through
WWDecode's read-only content gateway and bind that proxy to the selection before calling the
package-scoped executor. No actual episode was opened by this revision. Automated fixtures
are synthetic.

## Reviewed open-weight candidate

The *only* production model pin is `LocalSpeechAssetPin.whisperBaseEnglish`, not
caller-supplied name/version/URL/license/hash strings. Its English ggml model contains the
tokenizer. The official [whisper.cpp model instructions](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/models/README.md)
link the [publisher's model repository](https://huggingface.co/ggerganov/whisper.cpp);
repository revision `5359861c739e955e79d9a303bcbc70fb988958b1`,
`ggml-base.en.bin`, **147,964,211 bytes**, SHA-256
`a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`.
The model repository declares MIT. This is an artifact-specific catalog admission,
**not** a rights conclusion for redistribution or bundled product release. No model body is
in the repository; no implicit download is implemented.

`scripts/stage-speech-candidate.sh <already-provisioned-official-model>` checks the
reviewed source hashes/sizes, regular-file/symlink-parent/dataless status and local staging
volume, then copies into a unique owner-private `/private/tmp/ww-speech-XXXXXXXX` directory.
It relocates Homebrew's absolute dylib references to the private directory, signs the
changed binaries ad hoc, and rejects any output byte other than the reviewed staged
checksums. The typed `ApprovedWhisperRuntime` catalog pins the exact relocated executable,
four linked dylibs, four possible dynamically loaded CPU/BLAS backends **and** model.
The installed sources are whisper.cpp **1.9.4** and ggml **0.25.3** with LLVM OpenMP
**23.1.2**; their exact original and staged hashes/sizes live in the staging script and
typed catalog. The ggml backends and whisper.cpp declare MIT, LLVM OpenMP declares MIT;
the macOS system libraries/frameworks are OS-supplied, not copied or claimed to be
independently pinned. Only the explicitly selected pinned CPU backend is made available
through `GGML_BACKEND_PATH`; attempts to discover Homebrew or other backends are denied.
This is **one local binary closure** and does not establish a portable macOS 26 bundle.

Before and after subprocess launch, the executor rehashes the model and every non-system
binary and checks path identity (including no symlink/dataless file), private directory
ownership and local volume. A replacement, absent library, altered dependency or partial
stage refuses inference. The subprocess uses `/usr/bin/sandbox-exec` with **deny default**
and **deny network***: literal read grants only for the staged files and the single PCM
input, ancestor-directory traversal, macOS runtime reads under `/System/Library`
and `/usr/lib` (never the writable `/System/Volumes/Data` alias), and writes only to a unique
owner-private scratch directory. Standard output/error are discarded through drained pipes
without storing diagnostics; a 120-second watchdog refuses a stalled subprocess. No source
path is writable; there is no `allow default`, downloader,
tokenizer fallback or inherited environment. The OS-supplied system runtime and same-UID
processes remain outside this sandbox's identity proof. Synthetic negative tests verify
that an unrelated read and write fail while selected input reads and scratch writes work.
The freshly staged closure returned JSON shape from a one-second synthetic silent WAV
under the minimal profile; no transcript text was printed. This does not replace a
monitored app/system-network cold-restart audit.

## Native status correction

`SpeechTranscriber.isAvailable == true` and `en_US` in `installedLocales` were observed on
the dev Mac, **but** `AssetInventory.status(forModules:)` for the configured transcriber
returned `.supported`, **not** `.installed`. Module asset readiness and native offline
inference are therefore **unproven**. No native provisioning was requested, no analyzer
or audio was submitted, and no native on-device result is claimed. A future no-download
admission probe must configure the exact locale/module and require `.installed`; all other
statuses refuse admission. Provisioning, rights, network and update behavior need separate
evidence within the approved scope.

## Remaining WW-026 gates

One-second **synthetic silence** only establishes process execution and JSON shape, not
word-timing or accuracy. The same approved selected-primary material, native status, app
adapter, frozen cold/warm/thermal/long-duration timing, word-time coverage, 16 GB/macOS 26
floor, warm RTF <=1, family peak <=8 GB, update/restart offline and transitive rights
remain open. No other speaker or backup is admitted by metadata. Keep #23 open and do not
use this candidate as production acceptance without independent review.
