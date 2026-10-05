# Proposed WhisperKit English-base evaluation

> **Publication notice:** This report describes archived historical evidence and phase permissions, not current execution authority. Public JSON companions are pointer-redacted and **NOT byte-identical archived mirrors**; [original versus published hashes](../planning/publication-provenance.json) are separate. Measurements, pins, artifact hashes, counts and failed controls remain unchanged. Local archive placeholders are not browsable repository links. [Current user-directed milestone policy](../planning/milestone-runbook.md) supersedes old no-issues/research-only phase restrictions without granting input consent.

**2026-10-04 · Pipeline proposal; no download/runtime approval.**
[Speech research](source-reconstruction-speech-readiness.md) · [exact machine allowlist](speech-evaluation-download-proposals.json), card `KIT-BASE-EN`.

| Item | Exact proposal |
| --- | --- |
| Code | `argmaxinc/argmax-oss-swift` at `f4e5d6be37ec820614fb0d72037e76c22d4c16f7` |
| Model | `argmaxinc/whisperkit-coreml` at `0f63a7800b00dd0226abd051b906c246e1907482` |
| Model files | `openai_whisper-base.en/`: **19 files / 146,707,731 bytes** |
| Model source | [Pinned CoreML directory](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en) |
| Tokenizer | `openai/whisper-base.en` at `911407f4214e0e1d82085af863093ec0b66f9cd6` |
| Tokenizer files | **Ten root JSON/TXT files / 3,938,516 bytes** |
| Tokenizer source | [Pinned tokenizer repository](https://huggingface.co/openai/whisper-base.en/tree/911407f4214e0e1d82085af863093ec0b66f9cd6) |
| Total allowlist | **29 files / 150,646,247 bytes**, exact paths/sizes/LFS hashes/Git OIDs in the companion JSON |

Model files include complete AudioEncoder, MelSpectrogram and TextDecoder compiled trees and configurations.
No upstream PyTorch alternate weights, other model directory, SpeakerKit/TTSKit or broad CLI is included.
Prefer the WhisperKit library product only.

**Stop before runtime:** `download:false` does not disable tokenizer Hub fallback.
At this pin, missing or invalid local tokenizer data can invoke a network load.
Require an explicit fail-closed local tokenizer contract and subsequent cold-restart network audit.
Neither has been implemented or tested here.

Pinned README macOS-14+/Xcode-16 prerequisites differ from the manifest macOS-13 resolver floor/Swift-tools-5.10.
Accepted macOS 26 permits evaluation eligibility, not build/model/device assurance.
Runtime/model-card MIT declarations do not cover vendored Hub/Tokenizers' Apache-2.0 obligations.
The converted model's separate LICENSE endpoint returned 404; conversion provenance and complete redistribution rights remain unverified.
Metadata hashes/OIDs are not downloaded-body verification; Git OID is not SHA256.

Later approval must name the 29-file download location/redirects/cancel/retry/verification, then separately the pinned library build/runtime, reference device and rights-cleared fixtures.
No native provisioning, package install, recording access or redistribution is approved.
**Owner:** Pipeline, Mac consulted. **Lead/user review recommended:** 2026-10-05.
Full source card: `parallel-readiness-20261004/pipeline/CARD_WHISPERKIT.md` under the session research root.
