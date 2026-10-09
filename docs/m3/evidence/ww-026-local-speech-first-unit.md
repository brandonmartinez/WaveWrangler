# WW-026 replacement: scoped local speech candidate

**2026-10-08; #23 remains PARTIAL.** This is a headless candidate, not app integration or
permission to infer from arbitrary files. `PrimarySpeechSelection` requires a unique,
user-confirmed primary channel. The selected-primary adapter decodes the selected channel through WWDecode's read-only
content gateway. The separate `preparePCMProxy` path derives a private, immutable in-memory
16 kHz Float32 mono proxy from that descriptor-verified decode for **unmapped** episodes,
with no source writes or output file. No actual episode was opened by this revision. Automated fixtures
are synthetic.

An earlier stacked adapter attempted accepted-map placement validation with fresh metadata
and the alignment dependency recipe. That was insufficient: caller-supplied snapshots
cannot attest organizer-owned activation, content-bound currency for all referenced
sources, all-lane inverse/coverage or same-fade authority. The #294 repair now refuses
**every recorded or accepted map before decoding**, including an unaccepted recorded map.
The caller-mintable action marker does not grant production authority; the offline plan
and worker remain `primaryProxyNotProven`, with no inference or app integration.

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
typed catalog. The ggml backends and whisper.cpp declare MIT; LLVM OpenMP's
[pinned upstream runtime source](https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-23.1.2/openmp/runtime/src/kmp_runtime.cpp)
declares **Apache-2.0 WITH LLVM-exception** (SPDX header). Redistribution and notices
clearance for the chosen closure remain open. The macOS system libraries/frameworks
are OS-supplied, not copied or claimed to be independently pinned. Only the explicitly
selected pinned CPU backend is made available
through `GGML_BACKEND_PATH`; attempts to discover Homebrew or other backends are denied.
This is **one local binary closure** and does not establish a portable macOS 26 bundle.

Before and after subprocess launch, the executor rehashes the model and every non-system
binary and checks path identity (including no symlink/dataless file), private directory
ownership and local volume. A replacement, absent library, altered dependency or partial
stage refuses inference. The subprocess uses `/usr/bin/sandbox-exec` with **deny default**
and **deny network***: literal read grants only for the staged files and the single PCM
input, ancestor-directory traversal, macOS runtime reads under `/System/Library`
and `/usr/lib` (never the writable `/System/Volumes/Data` alias), and writes only
to the literal result file in a unique owner-private scratch directory. The profile
refuses an input path under scratch; a pre-existing hardlink alias elsewhere in scratch
cannot be modified through its write grants. The result path could itself become an
alias without identity protection, so no runnable plan is admitted. Standard output/error
are discarded through drained pipes without storing diagnostics; a 120-second watchdog
refuses a stalled subprocess. No source is submitted while provenance is unproven;
there is no `allow default`, downloader, tokenizer fallback or inherited environment.
The OS-supplied system runtime and same-UID
processes remain outside this sandbox's identity proof. Synthetic negative tests verify
that an unrelated read and write fail while selected input reads and only result-file
writes work.
The earlier freshly staged closure returned JSON shape from a one-second synthetic silent WAV
under the old profile; no transcript text was printed. That observation does not validate
the tightened profile or replace a monitored app/system-network cold-restart audit.

**Admission is now default-deny even for a regular PCM file.** The package-scoped
`OfflineWhisperPlan` constructor explicitly refuses with `primaryProxyNotProven`, including
caller-attested primary metadata, synthetic hardlinks/symlinks, changed paths, and mismatched
selections. A caller cannot create a runnable plan from an arbitrary file. The separate
synthetic-worker input boundary below does not accept a pathname or construct an offline
plan. A future runnable adapter still needs qualified offline runtime and model rights,
an input format supported by that runtime, and a safe descriptor-only execution contract.
Neither approved real media nor a synthetic fixture is submitted through this runtime path.
The existing bounded watchdog, drained diagnostics and output refusal remain reserved for
that gated path.

**Selected-primary PCM proof unit (2026-10-08):** `preparePCMProxy` uses the same confirmed
primary, single selected channel, current source/format/asset revision and read-only
`SourceDecoder.withDecodingCursor` as `prepare`. It refuses every recorded/accepted map
before content access: no accepted occurrence, all-lane map inverse/coverage or same-fade
authority is inferred. The original descriptor is checked against metadata at open and
against descriptor/path identity after the last read; the selected file, bookmark, show
mutation serial and complete access-record set are rechecked **after** resampling and
before returning. The immutable proxy carries selection, full format interpretation
(including fingerprint, codec delay and channel layout), source revision, selected-channel
asset revision 2, proxy asset revision 1, and one-second-at-16-kHz chunk offsets. Each chunk
records half-open output/source frame spans and the clamped contributing source-frame span.
Exact center mapping is
`sourceFrame = outputFrame * (sourceRate / 16000)`; source times use the interpretation's
integer rate, not floating-point timestamps. Source frames beyond valid content contribute
zero only at filter edges. The 8-factor-per-side Blackman sinc lowpass (`0.45/factor`
cycles/source frame) follows the analysis-decimator recipe but is a separate unqualified
speech-proxy filter, proxy asset revision 1; 16 kHz is exact passthrough. Only envelope-supported
integral multiples of 16 kHz through 192 kHz are admitted; 44.1 kHz and other fractional
ratios **refuse**, not silently interpolate. Raw selected input is capped at 9,600,000
frames (at most ten minutes only at 16 kHz), and proxy chunks at 16,000 frames. Overflow,
rate mismatch, cancellation, stale live state, alias/path change and decode errors refuse
typed; staged output is scrubbed on failure and never published partially. The selected
proxy is memory-only and has no public sample or file-path constructor, no runnable
`offlinePlan`, and no ASR invocation. Descriptor pinning applies to the original decoder
read and to the synthetic-only worker input below; a mutable caller-supplied snapshot alone
cannot grant organizer-owned authority or durable source-content identity.

**Sealed synthetic-worker input unit (2026-10-08):** The debug-only, package-scoped
`withSealedSyntheticWorkerInput` reuses `prepareSelected`, requiring an exact
episode/speaker caller-declared authorization, confirmed non-backup primary, unique
user-confirmed source identity, fresh source/format/selected-input/proxy and organizer
revision, and *no episode maps*. While the verified cursor reads, it hashes only the
selected decoded source channel (domain-separated SHA-256 including channel, rate and
frame count), **not** the source file's container bytes or other channels. That hash
and the format/fingerprint bind the source side of the handoff. The selected channel is resampled
before canonical native little-endian Float32 mono bytes are written at 16 kHz into a
mode-0600 file inside a mode-0700 locally mounted private directory. A read-only
`openat(O_NOFOLLOW)` descriptor is inode/size checked against its private writer,
and the pathname is unlinked before delivery. The worker callback receives only a
synchronous borrowed FD plus a SHA-256 verified byte/format/frame/channel/selection,
declared intent, selected-source PCM hash, source fingerprint, interpretation,
chunk-coordinate and asset-revision
record. It has no file URL. Release builds expose no worker handoff. The same FD and digest are checked before and after the
callback; the retained private writer overwrites and truncates bytes on normal return,
worker refusal and cancellation, and both descriptors are closed. A synthetic worker
file is pinned/verified before decode, before callback and after callback; mismatches
refuse without publishing a result. After the last pre-worker awaited organizer read,
the selected source's bookmark is resolved afresh from that snapshot and its confirmed
record, path, fingerprint and file state are checked against the decoded input
**before the worker receives PCM**. After the callback, the full organizer snapshot
is read once more; only **after that awaited read** are the selected source's current
bookmark, pathname, fingerprint and file state checked again before result publication.
Synthetic tests suspend both reads and replace the source, rewrite its bytes,
or retarget its bookmark with an unchanged organizer snapshot: pre-worker changes
refuse without invoking the callback, and post-worker changes refuse the result.
Other tests cover selected-channel content,
modified bytes, source/path/revision races, wrong episode, mapped occurrences, worker
identity changes, cancellation and scrubbed anonymous bytes. This input is **raw f32le**,
not a runnable Whisper WAV or a grant of actual inference. Real model/native rights,
actual worker execution and monitored cold-restart offline qualification remain blocked;
no model, recording or network was used for this unit.

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

The earlier one-second **synthetic silence** only established process execution and JSON shape, not
word-timing or accuracy. The same approved selected-primary material, native status, app
adapter, frozen cold/warm/thermal/long-duration timing, word-time coverage, 16 GB/macOS 26
floor, warm RTF <=1, family peak <=8 GB, update/restart offline and transitive rights
remain open. No other speaker or backup is admitted by metadata. Keep #23 open and do not
use this candidate as production acceptance without independent review.
