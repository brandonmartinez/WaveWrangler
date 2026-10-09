# WW-026: pinned CPU speech source link (model-free)

**Status: preparatory, not transcription or offline acceptance.** Refs #23 #32. This
unit builds an in-process native C library into the signed app, but
`SpeechInference.infer` still checks the current confirmed Primary and always
throws `engineUnavailable`. Backups and ambiguous assignments still refuse
before any native call. No model, media adapter, tokenizer, transcript, or
source-content access is supplied to the C bridge.

## Exact source and rights

- Official source: [`ggml-org/whisper.cpp` v1.6.2](https://github.com/ggml-org/whisper.cpp/tree/c7b6988678779901d02ceba1a8212d2c9908956e);
  tag commit `c7b6988678779901d02ceba1a8212d2c9908956e`. The official
  [commit archive](https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/c7b6988678779901d02ceba1a8212d2c9908956e)
  downloaded outside the repository has SHA-256
  `92f2117f8d1aac59fdf732788085567816785441e036def1d9cf20953610db3e`.
- The 14 byte-identical vendored files in
  `Packages/WaveWranglerKit/Sources/WWWhisperNative/upstream/` are the upstream
  `LICENSE`, `whisper.cpp`, `whisper.h`, `ggml.c`, `ggml.h`, `ggml-alloc.c/.h`,
  `ggml-backend.c/.h`, `ggml-backend-impl.h`, `ggml-quants.c/.h`,
  `ggml-common.h`, and `ggml-impl.h`. Their ordered SHA-256 listing
  (`shasum -a 256` of those paths in that order, then SHA-256 of that listing)
  is `b4a7363a36dfeb9812b4d68d91f1b01f16af80edf4c9803aaf985f26033a9942`.
  `bash scripts/verify-whisper-native.sh` rejects changed or extra files.
- The included [MIT license](../../../Packages/WaveWranglerKit/Sources/WWWhisperNative/upstream/LICENSE)
  carries the ggml authors' copyright and permission notice; the additional
  MIT notice for Jeffrey Quesnelle and Bowen Peng remains in `ggml.c`. This
  notice is also copied byte-for-byte to
  `WaveWrangler/WhisperCPULICENSE.txt` for the app's resource bundle. This
  CPU-only subset has no bundled model, binary artifact or other upstream
  dependency. **Model weights have separate, still-unverified exact-artifact
  rights and hashes**; the user's one-time model-download approval is for a
  later unit, not used here.

The newer official v1.9.5 (`d1be6fde11ac6e0407606b4e42fe72d34add8037`)
unconditionally lists ANEForge in `src/CMakeLists.txt` and reads
`ANEFORGE_ENCODER` in `src/whisper.cpp`, even in a nominally CPU-only build.
The older official v1.6.2 retains a C ABI (`whisper_lang_id`,
`whisper_context_default_params`) and avoids ANEForge **and** the later ggml
dynamic-backend registry altogether. That materially simplifies this
model-free static link; this does not qualify v1.6.2 for a future model or
claim it is the final inference-engine selection.

## Build and bounded observation

SwiftPM compiles only the six specified C/C++ translation units (five upstream,
including `whisper.cpp`, plus `CPUBridge.c`) into a macOS arm64 static
`WWWhisperNative` product. C11/C++11 and the explicit source list leave
Metal, CoreML, BLAS, Accelerate, OpenMP, RPC, dynamic backends, curl, server,
examples and upstream tests out of this target. No `GGML_USE_*` accelerator
flag or shared-library flag is set. The C header exposes one no-argument
`ww_whisper_cpu_probe`: it calls the upstream C language ABI, squares four
generated floats and reports zero words and `inference_available=0`. It
cannot receive a model, path, media buffer, or network endpoint. The app
checks this symbol on startup in Debug **and Release**; it logs a failed link
check without enabling inference or blocking unrelated organizer work.

On the working macOS 27 / Xcode 27 Apple-silicon Mac: source hash check passed;
the `WWWhisperNative` static archive was arm64, with `ww_whisper_cpu_probe`,
`whisper_lang_id`, and the CPU backend present, and **no** ANEForge, `_dlopen`,
`_dlsym`, socket/connect/bind/listen, fork/exec, curl or OpenMP symbols in
that archive. The separately built ad-hoc signed Debug and Release apps
passed `codesign --verify --deep --strict`; those native symbols were
present in the Debug app's signed `.debug.dylib` and Release app executable.
The Release app's dynamic closure included system `libc++` and Apple
frameworks, not a whisper/ggml/backend dylib. Other existing app frameworks
include Network and Accelerate; **this is not a whole-app no-network proof**.
The signed Debug executable's headless synthetic argument reported four
frames, zero words, `backup=refused`, and `native=linked`; the eight focused
speech package tests passed in Debug and optimized Release without skips.
The 12 recursive source-content gateway tests also passed. The identical
MIT notice was present in both signed app resource bundles. These are
precommit targeted checks, **not** a clean exact-head full `scripts/test.sh`
gate. Upstream source emits compiler conversion warnings; no vendored bytes
were changed to suppress them.

**STOP before production inference or issue acceptance:** separately verify an
exact official model's rights, checksum and offline assets; bind the selected
Primary to a trusted content-gateway decode, occurrence and revision; measure
real in-app inference with that model. Correlate endpoint-denial errno values
with sandbox violation logs, inspect startup/inference FDs (including Unix
ingress and relay paths), confirm effective entitlements and no network
fallback, then run the frozen timing/accuracy and safety gates. The current
source-only bridge does not satisfy #23 or #32 or authorize M3 exit.
