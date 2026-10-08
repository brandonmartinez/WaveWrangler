# WW-026 first unit: local speech admission and candidate availability

**2026-10-08; #23 remains partial.** This unit adds `WWSpeech` metadata admission for
user-confirmed primary speaker channels, a pinned local asset verifier, and a
network-denied whisper.cpp command plan. It does not wire transcription into the
app, select an engine, provision Apple assets, qualify word boundaries or process
the permissioned episode. Its opt-in runtime check creates one second of synthetic
silent PCM in a disposable local directory, parses the result shape without
printing recognition text, and removes the synthetic output.

| Candidate | Observed on dev Mac (macOS 27.0.1, Apple M5 Max, 128 GB) | Limit |
| --- | --- | --- |
| Apple `SpeechTranscriber` | Framework API reports `isAvailable=true`; `en_US` in both `supportedLocales` and `installedLocales` (9 installed / 45 supported locales). No provisioning requested. | No sample processed; asset version, entitlement in the app, word times, device/locale floor, update behavior and system-network traffic **unknown**. Installed locale is not an offline-inference proof. |
| whisper.cpp | Homebrew `whisper.cpp` **1.9.4** installed; executable SHA-256 `13650fc8ffaaa4e637c6951f7d2e492916877e70bd1b7a266fbfd0bdc597719e`; linked `libwhisper.1.9.4.dylib` SHA-256 `c2c6624410d3308238d855b9ad1c201e578017c435616d644a1bbcbb3f030153`. Official project release [v1.9.5](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.5) exists but is **not** the installed runtime. | Local synthetic run succeeded under a sandbox with `deny network*`; not yet linked/bundled/pinned as a complete runtime, nor qualified for representative audio. |
| [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.1) | Official upstream currently redirects to `argmax-oss-swift`; v1.1.1 manifest declares Swift tools 5.10/macOS 13, but includes other product dependencies. No install/model/runtime checked. | Versioned product target, runtime/model asset floor, license/transitive inventory and tokenizer network behavior require separate resolution before adoption. |

**Downloaded model (one official-source fetch, outside the repository):**
`ggml-base.en.bin` (English base); [official whisper.cpp model instructions](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/models/README.md)
link the [publisher's model repository](https://huggingface.co/ggerganov/whisper.cpp).
Pinned model repository commit `5359861c739e955e79d9a303bcbc70fb988958b1`;
exact size **147,964,211 bytes**; official LFS SHA-256
`a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`,
verified after download and again through `LocalSpeechAssetPin.verify(at:)`.
The repository card declares **MIT**; [upstream OpenAI Whisper code](https://github.com/openai/whisper/blob/main/LICENSE)
and [whisper.cpp code](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/LICENSE) are MIT.
These declarations are recorded provenance, **not** a redistribution, patent,
all-transitives or product-rights conclusion. Model bytes are not committed.
The ggml artifact includes the tokenizer; this command plan has no tokenizer
download path. Homebrew runtime linkage includes `ggml` libraries and Apple
system libraries; complete transitive binary/hash/license and app-bundling review
remain outstanding.

**Synthetic result:** 4/4 focused tests passed with the pinned model available;
the one-second silent WAV subprocess exited 0 in ~1.87 s for the first observed
invocation and ~0.30 s in a later warm invocation, returning JSON with a
`transcription` array and timing-offset fields. An independent sandbox socket
connection to loopback failed with `EPERM`; an ordinary sandboxed local process
succeeded. Silence may elicit unsupported text/times; neither transcript words
nor timing fields count as validated word boundaries. The test invokes no
network-dependent tokenizer and provides a *sandbox boundary check*, not a
monitored cold-restart network audit. No original recording was read or
transcribed in this unit; all automated fixtures are synthetic.

**Required next gates before #23 acceptance:** pin the executable **and all**
linked runtime libraries/licenses and test the final packaged path; enforce
verified proxy provenance through WWDecode, explicit user-confirmed
primary/channel selection and private local scratch in the production adapter;
audit app and system network behavior after a provisioned cold restart and on
updates without changing network settings; compare Apple and the verified
open-weight candidate fairly on the same approved selected-primary material
and frozen timing, accuracy, resource (warm RTF <=1; family peak <=8 GB),
thermal, long-duration and macOS 26/16 GB strata. Record asset-specific
license/notices and unsupported word-time coverage honestly. Real-media
selection and timed execution require the confirmed episode assignments;
no backup or library-wide inference is authorized by this unit.
