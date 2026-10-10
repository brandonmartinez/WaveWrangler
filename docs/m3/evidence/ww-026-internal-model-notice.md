# WW-026: internal model NOTICE and provenance boundary

**Scope: internal M3 evaluation only.** The private working-Mac `ggml-tiny.en.bin`
evaluation used 77,704,715 bytes with SHA-256
`921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f`,
matching the [converted repository object at revision
`5359861c739e955e79d9a303bcbc70fb988958b1`](https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny.en.bin).
No model body, path, recording or private asset is included here. The published
MIT texts below support internal use; this record is not a legal conclusion or
permission to redistribute the converted model in a signed/public bundle.

## Pinned public evidence

The exact upstream responses below were independently SHA-256 checked at the
listed immutable revisions on 2026-10-09. The copyright, permission and warranty
texts are reproduced in full below, not substituted for the app's existing
native-source notices.

| Published source | Immutable URL | SHA-256 |
| --- | --- | --- |
| OpenAI Whisper LICENSE (2022 OpenAI) | [LICENSE](https://raw.githubusercontent.com/openai/whisper/3e1780fd37686666f568be9c99f5b5e3e4f2eb92/LICENSE) | `b5d65a59060e68c4ff940e1eddfa6f94b2d68fdf58ed7f4dd57721c997e35e9d` |
| OpenAI Whisper README (code **and model weights** MIT) | [README.md](https://raw.githubusercontent.com/openai/whisper/3e1780fd37686666f568be9c99f5b5e3e4f2eb92/README.md) | `9d1351c8f5d1036be1d08940d33ab50387c4ee1ab8cdc8265e36596e440d7a0f` |
| whisper.cpp LICENSE (2022 Georgi Gerganov; research snapshot) | [LICENSE](https://raw.githubusercontent.com/ggml-org/whisper.cpp/8e361d90d7948de3ecae73e10878040044836800/LICENSE) | `7cce16d2bf2e2ce6a7d70b5ecd5fb43c6409a97aa0750ff75c11823e6e8c9d05` |
| whisper.cpp README (research snapshot) | [README.md](https://raw.githubusercontent.com/ggml-org/whisper.cpp/8e361d90d7948de3ecae73e10878040044836800/README.md) | `a7c65e438bfb5fde5e04ffeb1ad9dca59d11a43ae0be63a3afe648705920fad9` |
| Converted `ggerganov/whisper.cpp` model card (`license: mit`) | [README.md](https://huggingface.co/ggerganov/whisper.cpp/raw/5359861c739e955e79d9a303bcbc70fb988958b1/README.md) | `21fd967098804f33fc84e803fb0e5ab7666d71801f4027cf28a65e7af09c1758` |
| Separate `openai/whisper-tiny.en` model card (`license: apache-2.0`) | [README.md](https://huggingface.co/openai/whisper-tiny.en/raw/74d3cae0a57362f468e23e66eb93aa3f3c693e34/README.md) | `c4a7eee7b55d1b1ab85e4c8bf634c98ccc0a0f881a3a7fed0103216e027b623a` |

### OpenAI Whisper LICENSE at `3e1780fd37686666f568be9c99f5b5e3e4f2eb92`

The text between the fences is byte-for-byte the pinned LICENSE
(SHA-256 `b5d65a59060e68c4ff940e1eddfa6f94b2d68fdf58ed7f4dd57721c997e35e9d`):

```text
MIT License

Copyright (c) 2022 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### whisper.cpp LICENSE at research snapshot `8e361d90d7948de3ecae73e10878040044836800`

The text between the fences is byte-for-byte the pinned LICENSE
(SHA-256 `7cce16d2bf2e2ce6a7d70b5ecd5fb43c6409a97aa0750ff75c11823e6e8c9d05`):

```text
MIT License

Copyright (c) 2022 Georgi Gerganov

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Shipped source versus converted model

The app vendors **whisper.cpp v1.6.2** at
[`c7b6988678779901d02ceba1a8212d2c9908956e`](ww-026-cpu-source-link.md),
not the later `8e361d90...` research snapshot above. The existing
[`WaveWrangler/WhisperCPULICENSE.txt`](../../../WaveWrangler/WhisperCPULICENSE.txt)
(SHA-256 `bf106da953584d6ecb709b5fb06bd797b6c2f963163b2cb2a0b5b96d9dd2bf33`)
already contains the complete vendored ggml MIT notice and YaRN attribution
and MIT notice. The vendored
[`WWWhisperNative/upstream/LICENSE`](../../../Packages/WaveWranglerKit/Sources/WWWhisperNative/upstream/LICENSE)
has SHA-256 `e562a2ddfaf8280537795ac5ecd34e3012b6582a147ef69ba6a6a5c08c84757d`.
Do not replace either shipped native-source notice with the later research
snapshot's license or mistake that snapshot for the shipped source revision.

Matching the converted model's output SHA-256 does **not** identify its exact
input checkpoint digest, conversion command/commit, mel-filter or tokenizer
asset revisions/digests, or the complete rights and notice chain for public
redistribution. The separate Apache-2.0 model card is not proof that it governs
this GGML object; the MIT/Apache card discrepancy remains unresolved. Those
questions and signed-bundle model grant/notices belong to Release WW-041/#39,
not a requirement for this internal synthetic test and not a passed #23 gate.
