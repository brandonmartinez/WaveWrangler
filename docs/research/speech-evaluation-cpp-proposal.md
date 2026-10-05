# Proposed whisper.cpp English-base evaluation

> **Publication notice:** This report describes archived historical evidence and phase permissions, not current execution authority. Public JSON companions are pointer-redacted and **NOT byte-identical archived mirrors**; [original versus published hashes](../planning/publication-provenance.json) are separate. Measurements, pins, artifact hashes, counts and failed controls remain unchanged. Local archive placeholders are not browsable repository links. [Current user-directed milestone policy](../planning/milestone-runbook.md) supersedes old no-issues/research-only phase restrictions without granting input consent.

**2026-10-04 · Pipeline proposal; no download/runtime approval.**
[Speech research](source-reconstruction-speech-readiness.md) · [exact machine allowlist](speech-evaluation-download-proposals.json), card `CPP-BASE-EN`.

| Item | Exact proposed artifact |
| --- | --- |
| Code | `ggml-org/whisper.cpp` at `60c0be6ac8fa71b1a2ae2dd938a31a34a508e774` |
| Converted model | `ggerganov/whisper.cpp` at `5359861c739e955e79d9a303bcbc70fb988958b1` |
| File | `ggml-base.en.bin`, unquantized English-only base |
| Source | [Pinned Hugging Face artifact](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin) |
| Expected bytes | **147,964,211**, metadata and HEAD Content-Length agree |
| Expected LFS SHA256 | `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002` |
| Code/license evidence | MIT at the pinned code revision; conversion README and official OpenAI code/weights MIT declarations, not full chosen-build clearance |

One file only. Upstream `base.en.pt`, CoreML encoder archives, quantized variants, VAD, diarization, converters and dependencies are excluded.
No artifact body was downloaded; expected size/digest is not independent body verification.
Conversion lineage does not attest the exact body/toolchain. The conversion repository's separate LICENSE endpoint returned 404.
Byte size is not peak memory or accuracy.

Later permissions must separately name the download location/redirects/cancel/retry/partial-file cleanup, pinned CPU/Metal/Accelerate build/runtime, reference device and rights-cleared fixtures/listening.
No microphone, user media, package install, provisioning or redistribution is included.
Word timing is documented experimental; no automatic filler acceptance.
Chosen build/transitive/generated notices, conversion provenance, Apple terms and remaining rights need review before distribution.

**Owner:** Pipeline. **Lead/user review recommended:** 2026-10-05, not an execution date.
Full source card: `parallel-readiness-20261004/pipeline/CARD_CPP.md` under the session research root.
