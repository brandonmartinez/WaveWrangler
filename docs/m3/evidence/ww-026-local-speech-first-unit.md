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
tokenizer. The official [whisper.cpp model instructions](https://github.com/ggml-org/whisper.cpp/blob/v1.9.4/models/README.md)
link the [publisher's model repository](https://huggingface.co/ggerganov/whisper.cpp);
repository revision `5359861c739e955e79d9a303bcbc70fb988958b1`,
`ggml-base.en.bin`, **147,964,211 bytes**, SHA-256
`a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`.
The model repository declares MIT. This is an artifact-specific catalog admission,
**not** a rights conclusion for redistribution or bundled product release. No model body is
in the repository; no implicit download is implemented.

### Explicit model provisioning and offline preflight (2026-10-08)

With the M3 model consent, `python3 scripts/provision-speech-model.py` performs an
**explicit, one-time** fetch of this exact commit-pinned publisher artifact. The
[v1.9.4 project model index](https://github.com/ggml-org/whisper.cpp/blob/v1.9.4/models/README.md)
points to the publisher's `ggerganov/whisper.cpp` repository. The publisher revision
declares **MIT**; the model's underlying redistribution rights and the complete binary
closure's transitive notices remain **unqualified**. This is not release clearance.

The pinned HTTPS resolver returned a single redirect to the publisher's Hugging Face
CDN host `us.aws.cdn.hf.co`, `X-Linked-Size: 147964211` and
`X-Linked-Etag: a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`.
The CDN returned the same content length. The **one downloaded body** was locally
measured as **147,964,211 bytes**, SHA-256
`a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`;
it is owner-private in the local asset store outside the repository. Neither the
signed redirect URL nor the private absolute store path is recorded here. Subsequent
`python3 scripts/provision-speech-model.py --check` rehashes it **without network**
(including after cold restart); re-running the provision command on a present model
rehashes instead of downloading again, and refuses a changed or broken asset.
`scripts/stage-speech-candidate.sh` accepts the already-provisioned file separately
when all exact local runtime pins are available. On this Mac, one offline trial
verified every staged executable, dylib, backend and model pin; the disposable
stage was removed afterward. Neither command constructs an `OfflineWhisperPlan`
or performs inference.

The preflight now installs macOS's **thread-scoped dataless-materialization OFF**
policy before checking any existing asset or staged file. It refuses an unavailable
or ineffective policy, and restores the previous policy after checking. Pre-open
`lstat` refuses dataless files, symlinks and hardlinks; descriptor and pathname
identities are compared before and after hashing, including staged-link adoption.
Synthetic negative tests verify no file open or network attempt on a dataless
placeholder or policy failure, and reject replacement during open/hash or adoption.
The macOS policy transition and restoration are tested on the host, but **no live
File Provider trial or monitored cold-restart traffic measurement** is claimed.
The follow-up stacked staging revision replaces the shell hash/copy path with
descriptor-pinned Python copying under the same thread policy. Staging verifies
all ten source files before creating an owner-private temporary directory, then
rehashes the same open descriptor as it copies each file; it compares source
pathname, descriptor, parents and output identity before and after the copy.
Each `install_name_tool`/ad-hoc `codesign` child installs a verified process-scoped
no-materialization policy **before exec** (which survives exec on the tested dev
Mac), and every staged output and source is rechecked while the parent thread
policy is active. An unavailable/ineffective policy, changed/dataless/linked
asset, unexpected output, subprocess failure or policy restoration failure
refuses publication and removes the private temporary stage. Synthetic tests
cover all ten assets, policy failures, intervening dataless status, replacement,
relink, mutated output and failure cleanup without reading private model bytes
or running inference. A live File Provider race, Apple cold-restart traffic
audit, offline rights and actual-media/full-gate qualification remain open.

Provisioning rejects an absent/changed publisher size or digest, unexpected redirect
host or scheme, CDN redirect, oversized/truncated/mismatched body, symlinked store or
model, and altered on-disk bytes. The HEAD request inspects the official commit-pinned
resolver first; the single GET targets only its approved HTTPS CDN destination and
never follows a further redirect. `scripts/test-provision-speech-model.py` uses synthetic
responses with **no network** to check these failures and the offline second check.
The package speech boundary suite additionally verifies that its default-deny
`sandbox-exec` profile blocks a loopback TCP connect that succeeds without the
profile. These structural controls are not a measured cold-restart app/system traffic
audit; system-managed Apple speech provisioning/update traffic and exact binary
transitive notice clearance remain unknown.

`scripts/stage-speech-candidate.sh <already-provisioned-official-model>` delegates
to the protected Python staging implementation, checking the reviewed source
hashes/sizes, regular-file/symlink-parent/dataless status and local staging
volume, then copying into a unique owner-private `/private/tmp/ww-speech-XXXXXXXX` directory.
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
selections. A caller cannot create a runnable plan from an arbitrary file. A future adapter
must derive an independent proxy through WWDecode's read-only content gateway from the
specific confirmed source/channel, bind its bytes to that selection, keep it outside
scratch, and prove the input/output cannot be re-aliased or replaced between admission and
execution. Until then neither approved real media nor a synthetic fixture is submitted
through this runtime path. The existing bounded watchdog, drained diagnostics and output
refusal remain reserved for that gated path.

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
