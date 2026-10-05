# Source reconstruction and local speech readiness

> **Publication notice:** This report describes archived historical evidence and phase permissions, not current execution authority. Public JSON companions are pointer-redacted and **NOT byte-identical archived mirrors**; [original versus published hashes](../planning/publication-provenance.json) are separate. Measurements, pins, artifact hashes, counts and failed controls remain unchanged. Local archive placeholders are not browsable repository links. [Current user-directed milestone policy](../planning/milestone-runbook.md) supersedes old no-issues/research-only phase restrictions without granting input consent.

**2026-10-04 · Pipeline execution; Lead review; parent publication.**
**Disposition: source-recipe mechanics and pinned documentary evidence, not SRC/ASR/DAW approval.**
[Exact results](source-reconstruction-speech-readiness-results.json) · [download allowlists](speech-evaluation-download-proposals.json) · [reconciliation](parallel-readiness-reconciliation.md).

Original sources, cards, raw evidence, fixture truth and code remain at:

```text
<research-artifacts>/research/parallel-readiness-20261004/pipeline/
```

This is a concise integration of `REPORT.md`, not independent reproduction.
No recordings, model/tokenizer bodies, runtime ASR, installed-locale/asset query, provisioned assets, microphone, DAW GUI or listening were used.

## Actual original-source regeneration

Fresh immutable PCM WAV files, not supplied aligned arrays, feed serialized source/occurrence/map/SRC/gain/edit recipes.
The record retains primary assignments, optional backup references, epochs, gaps, required originals, requested/actual half-up frame boundaries, common kept spans, baked fade identity and schema/recipe versions.
Restoration regenerates the accepted aligned baseline from originals, **not from cleaned stems**.

| Observations across seven fresh source cases | Actual result |
| --- | --- |
| Source regeneration | 7/7 compare against a separate rational original-PCM oracle. |
| Restoration | 7/7 reconstruct from originals and the serialized record. |
| Boundary/mode edit, reload, Undo/Redo | Four observations regenerate actual WAVs; Undo is byte-identical. |
| Output-preserving refusals | 13/13 refuse before publication and preserve stems/mapping/record bytes. |
| Faulty encoded-WAV controls | Three detected: independent one-frame ripple, doubled fade and silent/reject-all output. |

**34 named observations, zero unexpected failures**, not 34 independent recordings.
Maximum oracle difference is **one PCM step**. Default outputs are zero-origin 48-kHz/24-bit mono PCM WAV; one case exercises 32-kHz/16-bit.
Both primary speaker stems share rate, map and duration; repeated occurrences, padding and protected synthetic intervals are represented.

Refusals include missing/changed originals, newer schema/recipe, malformed history/cursor/state, stale primary/map/edit revisions, double-baked processing, protected overlap and **isolated omitted boundary evidence**.
The last case narrows an earlier confounded reload gap; it does not establish a general validator.
Inputs/truth/code were frozen before seven-case qualification; 70 entries remain unchanged.
Three calibration cases were repeated before freeze, not six independent calibration cases.

**Renderer limitation:** this probe uses linear interpolation and nonoverlapping edge tapers.
It proves source-recipe reconstruction mechanics, **not fidelity-qualified SRC, native preview, actual crossfades or listening quality**.
Alignment's separate bandlimited candidate is also unqualified; neither is adopted.
No native/DAW import means interoperability remains unproved.

## New merged-fade risk

Lead inspected `probes/renderer.py`: per-cut footprints are checked before union, then the largest fade can be promoted to both merged outer edges.
Illustration, **not executed**: adjacent `[100,110)`/fade 0 and `[110,120)`/fade 10 can add an unchecked `[90,100)` leading footprint.
Represented merged-cut cases all use equal fades and retain their passes.
**Pipeline owns per-edge merge semantics and revalidation of the final effective footprint** against protection and bounds, with Alignment consultation.
This source-audit risk is not a fabricated failed experiment or a corrected frozen candidate.

## Speech candidates: no engine selected

| Candidate | Verified evidence | Unmeasured/gated |
| --- | --- | --- |
| Native SpeechTranscriber | Apple macOS-26 API documentation; target-26, Swift-language-6 object-only compile of attributed timing/confidence APIs. | Device/en-US eligibility, system-managed asset size/hash/version, provisioning, accuracy, offline audit and service-family memory. |
| whisper.cpp | Pinned ARM/Metal/Accelerate-capable code and English `base.en` converted checkpoint; word timestamps documented experimental. | Body/conversion attestation, chosen build/BOM, recognition/boundary quality, resource/device/offline evidence. |
| WhisperKit | Pinned CoreML `base.en`, separate tokenizer and library-only build recommendation. | Runtime/model compatibility, conversion/notices, accuracy and fail-closed offline loading. |

**WhisperKit `download:false` is not sufficient offline assurance.**
At the inspected code pin, [`ModelUtilities.loadTokenizer`](https://github.com/argmaxinc/argmax-oss-swift/blob/f4e5d6be37ec820614fb0d72037e76c22d4c16f7/Sources/WhisperKit/Utilities/ModelUtilities.swift) falls back to Hub when local tokenizer loading is missing or fails; this path has no download flag.
A valid pinned local tokenizer and a fail-closed loader are required before an authorized runtime, followed by a cold-restart network audit.
No such guard was implemented or exercised here.

WhisperKit's manifest macOS-13 resolver floor differs from README macOS-14+/Xcode-16 prerequisites; neither is a measured support promise.
The accepted macOS-26 target clears eligibility floors, not actual device/build qualification.
MIT root/model-card assertions do not subsume vendored Apache-2.0 Hub/Tokenizers or complete chosen-build/converted-model redistribution clearance.
Native Apple assets are system-managed, not an approved redistributable bundle.
Pinned source retrievals, license observations and failed endpoints are in `SOURCE_LEDGER.md` and `raw/*source-ledger.json`.

## Exact, unapproved evaluation proposals

| Proposal | Pin and allowlist | Size |
| --- | --- | ---: |
| [CPP English base](speech-evaluation-cpp-proposal.md) | One `ggml-base.en.bin`; exact source/revision/LFS digest. | 147,964,211 bytes |
| [WhisperKit English base](speech-evaluation-whisperkit-proposal.md) | 19 compiled model files plus ten pinned tokenizer files. | 150,646,247 bytes |

The [machine allowlists](speech-evaluation-download-proposals.json) are exact metadata, **not approved downloads or body verification**.
Native provisioning remains a separate unknown-size request.
Download, build/runtime, native metadata/provisioning, rights-cleared recordings/listening and redistribution each require their own scope.

## Owned action and accounting

**Pipeline, Lead/Mac review recommended 2026-10-05:** decide evaluation scope/cards, fail-closed tokenizer/BOM, merged-fade validation and a shared qualified SRC/recipe adapter.
Fair later comparison requires the same named macOS-26/Apple-silicon/16-GB device, independent word/proposal truth, frozen settings/coverage, offline checks and app+child+service memory.
No future experiment is authorized by this recommendation.

One native compile, object-only; two bounded reporting/retrieval cycles, no post-freeze PCM tuning.
All owned processes ended. Host: macOS 27.0.1/arm64/128 GiB, Python 3.14.8 and Swift 6.4, not reference-device proof.
WW-003/026/028/036/043 gain scoped evidence; WW-025/035/044 gain planning inputs, without item completion or production permission.
