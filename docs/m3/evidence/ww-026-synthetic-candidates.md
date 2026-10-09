# WW-026 synthetic candidate qualification (preparatory, not adoption)

**Scope:** English synthetic PCM only, on the working Mac. No episode, microphone,
private transcript, cloud ASR, network-setting change, native asset request, or
model-body copy in this repository. This is a calibration comparison, not the
macOS 26 / 16 GB / representative-audio gate in #23. The selected-primary sealed
worker and staged episode evidence are separate work.

## Reproduce and failure boundaries

`scripts/speech-qualification.py` generates two fixed English utterances with
the locally installed Samantha voice, converts each to 16-kHz mono 16-bit WAV,
and feeds **the same temporary PCM file** to each available candidate. It
refuses other input files. All audio, ASR JSON and transcription text stay in a
temporary directory outside Git and are removed on exit. Stdout contains only
aggregate counts, WER against the synthetic text, elapsed/RTF and resource
measurements. No recognition text is committed.

```sh
# Native compiler output and all media stay outside the worktree.
xcrun swiftc -parse-as-library -swift-version 6 \
  -target arm64-apple-macosx26.0 \
  -o "$TMPDIR/ww-speech-native-probe" scripts/speech-native-probe.swift
python3 scripts/test-speech-qualification.py -q
python3 scripts/speech-qualification.py \
  --model "$HOME/Library/Application Support/WaveWrangler/SpeechModels/ggml-base.en.bin" \
  --whisper-cli /opt/homebrew/bin/whisper-cli \
  --native-probe "$TMPDIR/ww-speech-native-probe"
```

The script requires the exact 147,964,211-byte SHA-256
`a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`
of `ggml-base.en.bin`, and whisper.cpp CLI version 1.9.4 with installed
executable SHA-256
`13650fc8ffaaa4e637c6951f7d2e492916877e70bd1b7a266fbfd0bdc597719e`.
Different binaries fail closed until their source/build and hash are reviewed.
The model is the
unquantized `base.en` conversion in `ggerganov/whisper.cpp` revision
`5359861c739e955e79d9a303bcbc70fb988958b1`, from its
[pinned official-source artifact](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin).
The tokenizer is embedded in the ggml model: this path never invokes
WhisperKit or a Hub tokenizer loader. The existing local file matched the
archived official LFS digest and byte count, so no duplicate download occurred.
This establishes artifact identity against that published digest, **not**
conversion-chain attestation or redistribution clearance.

The installed Homebrew whisper.cpp 1.9.4 formula points to the upstream
`v1.9.4` source tarball and SHA-256
`57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae`;
its local LICENSE is MIT. The linked ggml license is MIT; Homebrew also
declares llama.cpp (MIT) and sdl2-compat as formula dependencies, while
Apple frameworks and dynamically loaded ggml backends have their own terms.
The converted model card/upstream weights assert MIT, but the conversion
repository's separate LICENSE endpoint was unavailable in the archived
research. Artifact-specific notices, conversion provenance, complete chosen
build/transitive notices, and redistribution rights **remain unresolved**;
none of these files is redistributed by this unit. See the
[original candidate card](../../research/speech-evaluation-cpp-proposal.md)
and [exact allowlist](../../research/speech-evaluation-download-proposals.json).
The Homebrew runtime is not the earlier proposal's pinned code revision;
its version and actual executable SHA-256 are emitted in each record.

Every synthetic generator, native probe and inference child is launched under
`sandbox-exec` with `(deny network*)`. Before any input or inference, two
negative controls require the sandbox to reject loopback IP `bind` and
`connect` with `Operation not permitted`; neither sends packets to an external
endpoint. A missing/changed model, wrong runtime, broken sandbox, absent output
or malformed result aborts the whole run. This is a **process-boundary**
no-egress control, not an OS-wide network-disconnection trial.
Whisper's single ggml file avoids the known WhisperKit
`download:false` tokenizer fallback; it does not establish a general
WhisperKit offline guarantee.

Each subprocess starts in its own process group, including `/usr/bin/time -l`
around sandboxed Whisper. A timeout or keyboard interrupt terminates the
group, escalates to SIGKILL if necessary, and reaps the direct child before
the temporary PCM and JSON are removed. The synthetic Python regression
stalls a nested child that ignores SIGTERM and verifies it is gone before
temporary input cleanup. This is process-lifetime safety, not a new
inference, offline-service, or WW-026 acceptance result.

The Swift probe checks en-US `supportedLocale`, `installedLocales` and
`AssetInventory.status(forModules:) == .installed`, in that order. It does
not call `AssetInventory.reserve` or download assets. `.supported` without
`.installed` is reported `supportedOnly` and native inference is **NOT_RUN**,
not a native pass. Even when installed, the sandbox restricts only the probe
process; Apple's Speech service may be outside it. The orchestrator therefore
marks native inference **BLOCKED** on an installed host until service-level
no-egress instrumentation exists; the compiled Swift probe is not an offline
qualification by itself. Asset hash/version,
system-managed update behavior and service egress remain **UNKNOWN** until
separately instrumented and reviewed.

`/usr/bin/time -l` records the timed process's maximum resident set size in
bytes, **not** total process-family, GPU, or Speech-service peak. Wall-time RTF
includes synthetic-file invocation and fresh process/model load; it is not
warm-session RTF. These results cannot certify the provisional warm RTF <=1
or family peak <=8 GB acceptance gates. Word boundaries are not independently
scored by this probe; segment timestamps alone do not prove word accuracy.

## Cold restart and final qualification protocol

On a separately scheduled quiet-host run, preserve a reviewed pre-restart
aggregate report and executable/model hashes outside any model directory.
Restart normally **without toggling network settings**; verify a different
`host.bootEpochSeconds` in the post-restart report, rehash the same provisioned
model and runtime, re-run the
loopback-denial controls and both fixed PCM cases **without fetching any
asset**. A source-tree or tokenizer path requiring a download must fail
before inference. For native Speech, first establish a genuinely installed
en-US asset, record its observable inventory/version (mark hash UNKNOWN if
Apple does not expose one), and instrument the system Speech service's
outbound flows as well as the app/child process; an absent or incomplete
service-level observer means zero-network status remains UNKNOWN. Do not
turn off network to manufacture a pass. Freeze a chosen build and its
notices before a representative-audio/16-GB/macOS-26 resource gate. Neither
this synthetic run nor a `.supported` locale authorizes engine adoption.

## Recorded local observations

The existing model file matched the 147,964,211-byte published LFS SHA-256.
The working host is Apple M5 Max, macOS 27.0.1, 128 GiB (not the 16-GB
reference). At **2026-10-08 20:05 ET**, one-minute load was **10.45** before
the bounded one-pass synthetic measurement (4 CLI threads; no Mini use).
Homebrew whisper.cpp 1.9.4 and the already-present model passed the size/hash
checks; the sandbox denied both local IP controls. The native probe compiled
for the macOS-26 deployment target under the installed macOS-27 SDK, and
reported `en_US: supportedOnly` with asset version/hash UNKNOWN. Native
inference was **NOT_RUN**. The full aggregate-only
[raw record](ww-026-synthetic-results.json) pins the executable hash and boot
session; no audio/model body or transcription text is included.

| Same synthetic PCM | Audio duration | Whisper wall / RTF | Timed-process max RSS | Synthetic WER | Native |
| --- | ---: | ---: | ---: | ---: | --- |
| Case 1 | 2.543 s | 0.222 s / 0.087 | 381,763,584 bytes | 0/8 | NOT_RUN: supported only |
| Case 2 | 2.854 s | 0.223 s / 0.078 | 382,042,112 bytes | 0/9 | NOT_RUN: supported only |

One segment with a nonempty time range appeared in each Whisper output; that
is **not** word-timing validation. No measured native RTF/RSS exists, no
process-family peak was captured, and the OS Speech service was not
network-audited. Warm/cold-restart, thermal, long-episode, macOS-26/16-GB,
representative audio, rights and redistribution remain **UNKNOWN**. The
synthetic WER/RTF cannot select an engine or close #23.
