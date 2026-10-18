# Transcription engines: editing-first research

Research date: 2026-10-17 UTC (2026-10-16 local session start).
Scope: research and isolated public-audio experiments, not production integration.

## Recommendation

**Keep the Whisper-family direction for now; do not adopt the eg2.haku.sh app as
WaveWrangler's transcription engine.** This is a feasibility/evidence decision,
not a measured claim that Whisper beats that exact app: its shipped reader and
weights were not available in the inspected public sources for an equivalent
headless benchmark.

We **did** run a separately labelled open reproduction of the same approach,
`john-rocky/eg2-transcribe` reader v2, on the identical public conversational
clips: **34.86% WER and 0/29 exact `um`/`uh` tokens**, versus **7.75% and 28/29**
for disfluency-prompted Whisper turbo. Those results favor Whisper for this
editing use case, but are not scores for the closed demo or a diverse holdout.

The important measured result is that **ordinary Whisper output is not reliably
verbatim enough for filler editing either**. On this small conversational pilot,
unprompted turbo retained none of 29 reference `um`/`uh` tokens. A disfluency-style
prompt raised retention to 28/29 and reduced strict WER from 19.72% to 7.75%, but
the same model still hallucinated "Thank you." on digital silence. This is a
promising next evaluation configuration, not a production qualification or an
automatic-cut permission.

## Existing project baseline

The isolated research branch was fast-forwarded to the accepted local MVP commit
`7b1ad2dde3f7a43c7d7543cf7915f5b75fbe4062`; ancestry was then verified. The main
checkout was not modified.

The actual current APIs are deliberately incomplete:

| Surface | Current behavior |
| --- | --- |
| `WWSpeech/SpeechInference.swift` | Checks the explicitly confirmed selected Primary/channel, then refuses with `engineUnavailable`. No production recognizer is enabled. |
| `WWSpeech/VerifiedTinyModel.swift` | Pins the 77,704,715-byte `tiny.en` artifact by SHA256; requires an already materialized, regular local file and unchanged identity. |
| `WWSpeech/BoundedPCMInference.swift` | Experimental caller-supplied PCM only: exactly 32,000 mono samples at 16 kHz (two seconds). Returns segment text/timing; explicitly no supported word timing/confidence. |
| `WWWhisperNative/CPUBridge.c` | Vendored whisper.cpp v1.6.2 CPU path, two threads, greedy decoding, no GPU, context or token timestamps; not the external runtime measured below. |
| Earlier [cpp](speech-evaluation-cpp-proposal.md) / [WhisperKit](speech-evaluation-whisperkit-proposal.md) proposals | Proposed `base.en` experiments, not implemented production baselines. The WhisperKit proposal specifically flags tokenizer network fallback despite `download:false`. |
| `WWWordEvaluation` / `WWCutPolicy` | Separate timing/proposal evaluation and protected-cut admission. Raw recognition confidence or engine timestamps are not supported cut boundaries. |

The pilot uses the same pinned tiny weights and proposed base weights through
an **external whisper.cpp v1.9.4 CLI**, plus a modern quantized turbo candidate.
It does not measure the app's two-second v1.6.2 adapter or WhisperKit/Core ML.
No app, selected-Primary policy, accepted timing or export code was changed.

## What the Gemma demo actually is

The [demo](https://eg2.haku.sh) describes a frozen **EmbeddingGemma 2 audio
encoder**, a separately trained reader mapping acoustic frames into its text
embedding space, nearest-word selection from about 229,000 English words, and a
separate punctuation/capitalization model. It is not simply a generic Gemma chat
model being asked to transcribe. Embedding similarity by itself is not a
transcript API: the trained reader, vocabulary, decoding and chunk handling are
essential parts of the proposed ASR system.

The site reports about 5% WER and an hour in 12.6 seconds on an M3 MacBook Air's
Neural Engine. These are **developer claims**, with no named accuracy test set
or scoring recipe on the landing page. The site itself says its cross-device
speed table is not a like-for-like ranking. None of those figures are measured
results from this session, nor comparable to the WER table below.

The site claims local/offline audio processing. That is plausible for an
on-device encoder/reader, but is not a network audit of the distributed app.
No private audio was supplied to the site, app, a model service or this benchmark.
No microphone or Accessibility permissions were granted.

The [independent `john-rocky/eg2-transcribe` implementation](https://github.com/john-rocky/eg2-transcribe)
and its [reader card](https://huggingface.co/mlboydaisuke/EmbeddingGemma-2-Transcribe-Reader)
explicitly distinguish their independently trained code/weights from the
closed app. Their 200,000-word vocabulary and reader are **not** the demo's
229,000-word reader. Their published LibriSpeech accuracy, even if reproduced,
would not establish the exact app's accuracy or spontaneous-podcast filler recall.

The [official base model card](https://huggingface.co/google/embeddinggemma-2)
identifies EmbeddingGemma 2, a Gemma-4-generation multimodal embedding model
(744,371,512 parameters in the inspected checkpoint metadata), not the earlier
text-only EmbeddingGemma model or a generic Gemma instruction model.
Our independently runnable combination is pinned as follows:

| Component | Revision | Role / terms |
| --- | --- | --- |
| `google/embeddinggemma-2` | `914f7f89142e33e77833254d9c9b90c3cef7303b` | Frozen encoder; card declares Apache-2.0. |
| `mlboydaisuke/EmbeddingGemma-2-Transcribe-Reader` | `de224fd8fa4ed4519fdddd9aa4154432d46a1bd3` | Reader v2: six-layer, 19,573,762-parameter bidirectional transformer, learned CTC blank and scale, 200,000-word table; Apache-2.0 with its own NOTICE. |
| `john-rocky/eg2-transcribe` | `e6b7d5df02fcfe940c194d00ad5d055f958b9c6c` | Apache-2.0 reference encoder extraction / reader decoding code. |
| Optional CoreAI conversion, not run | `76865ae46793e05617c2a7420454b0c7eb8541a4` | [Mac/iOS conversion](https://huggingface.co/mlboydaisuke/EmbeddingGemma-2-Transcribe-CoreAI), distinct from the demo. |

The original app advertises v1.6, macOS 14+ and Apple silicon. Its inspected
public description did not supply a reusable reader license or engine SDK;
free-of-charge app download is not permission to embed it. The independent
CoreAI port requires macOS 27/Xcode 27 and has a headless `--selftest transcribe`
path, but no prebuilt GitHub release was available. Its documented default Mac
pipeline uses **GPU encoder plus ANE reader**; do not attribute this separate
port's configuration to the original app or assume end-to-end ANE parity.
Our test uses neither compiled app nor that CoreAI conversion.

License caution: Google's [Gemma 4 announcement](https://opensource.googleblog.com/2026/03/gemma-4-expanding-the-gemmaverse-with-apache-20.html)
and base card say Apache-2.0, unlike earlier Gemma generations; the older
[Gemma terms](https://ai.google.dev/gemma/terms) exclude Gemma 4. However the
independent reader's [NOTICE](https://huggingface.co/mlboydaisuke/EmbeddingGemma-2-Transcribe-Reader/blob/de224fd8fa4ed4519fdddd9aa4154432d46a1bd3/NOTICE)
also says deployments must adhere to the Gemma Prohibited Use Policy and asks
redistributors to retain LICENSE/NOTICE. Resolve that notice/base-terms
discrepancy before shipping, rather than inventing a blanket Gemma-family
license. The Google Apache-license documentation page's legal body was not
retrievable with the research fetcher. This session redistributed no weights.

An English word lexicon also raises concrete questions about proper names,
partial words, interjections, repetitions and silence/blank decoding. It does
not prove those fail: inspect the exact vocabulary and test them. A frame
classification every approximately 40 ms can supply alignment evidence, but
frame cadence is not independently validated phonetic onset/offset accuracy.
The demo's inspected description does not establish a supported word-timestamp
export/API or a cut-safe timing contract.

The open replica's `vocab.txt` **does contain `um` and `uh`**, verified locally.
Its failure below is not because those classes are absent. The learned
acoustic/read-speech distribution appears poorly suited to these spontaneous
hesitations in this pilot: outputs include `am`, `an`, `a` and `m` instead.
Its ordinary Python decoder emits plain words, not timestamps; the Swift
transcription result likewise has no word-time field. CTC frame labels would
need a separately validated word-boundary adapter or forced alignment.

Long-form differs by implementation. Whisper's normal transcription uses
30-second windows and context-dependent decoding; boundary duplication,
omission and silence hallucinations require long-form evaluation. The replica
config specifies 30-second windows, 96 left-overlap tokens (3.84 seconds) and
one right-extra token to address encoder edge effects. Original demo chunk
policy is not documented in the inspected landing page. **No multi-hour or
cross-30-second benchmark was run here**; the longest measured excerpt is
27.85 seconds. A fast short-clip pipeline does not establish reliable episode
continuity.

## Local public-audio pilot

### Corpus and protocol

Source: **AMI Meeting Corpus**, meeting ES2002a, speaker B, headset channel 1.
The [corpus publisher](https://groups.inf.ed.ac.uk/ami/corpus/) licenses signals
and transcription under **CC BY 4.0**. Attribution: AMI Meeting Corpus,
University of Edinburgh / AMI Consortium. The [manual annotation download](https://groups.inf.ed.ac.uk/ami/download/)
is version 1.6.2.

Unlike clean audiobook speech, this reference was [transcribed verbatim](https://groups.inf.ed.ac.uk/ami/corpus/transcription.shtml).
Its [guidelines](https://groups.inf.ed.ac.uk/ami/corpus/regularised_spellings.shtml)
explicitly require retaining filled pauses, reduced forms and false starts.
The transcript is human-authored; its word times are **automatically forced
aligned**, not hand-verified cut-boundary ground truth.

Six source excerpts total **117.63 seconds, 284 normalized reference words and
29 exact `um`/`uh` tokens**. They include repetitions, a partial word, numbers
and the names David, Andrew and Craig. Source-time windows, in seconds:

| Clip | Half-open source interval | Words | `um`/`uh` |
| --- | --- | ---: | ---: |
| ami-01 | [55.73, 67.55) | 29 | 3 |
| ami-02 | [92.48, 102.00) | 26 | 2 |
| ami-03 | [108.71, 132.20) | 66 | 7 |
| ami-04 | [142.66, 165.91) | 51 | 4 |
| ami-05 | [394.62, 422.47) | 64 | 8 |
| ami-06 | [465.51, 487.21) | 48 | 5 |

Windows were chosen from annotations before inference, with a preflight refusing
partly clipped reference words. The initial proposed boundaries failed that
preflight and were corrected before any inference. The first clip includes one
annotated other-speaker backchannel; scoring targets speaker B's close-talk
track, not a mixed-speaker transcript. There was no manual listening or
independent boundary adjudication.

This is **one speaker in one elicited design meeting**, not a held-out diverse
podcast qualification set. ES2002a is an AMI training meeting; model pretraining
contamination is unknown. No conclusion about broad accents, difficult overlap,
noise, long-form continuity or filler-removal precision follows from 284 words.

Input conversion is unnecessary: publisher WAV is already mono PCM16/16 kHz.
Every engine receives byte-identical cropped WAVs, with hashes recorded.
A separate ten-second all-zero PCM16 control has an empty reference.

Scoring lowercases and tokenizes ASCII alphanumerics/internal apostrophes;
punctuation and hyphens split. It **does not remove fillers or repetitions**,
expand numbers/contractions or alias British spellings. Thus `twenty five` versus
`25` and `gonna` versus `going to` are strict text differences. WER is
micro-averaged `(substitutions + deletions + insertions) / 284`. Exact `um` and
`uh` recall/precision use the same deterministic minimum-edit alignment;
`like`, `well`, meaningful uses and multiword fillers are not classified.
`[BLANK_AUDIO]` is recorded as a non-speech label, not two invented spoken words.
The empty-reference control reports emitted words, not an undefined/false 0% WER.

### Runtime and settings

Machine: Apple M5 Max, 128 GiB unified memory, macOS 27.0.1 (26A434), arm64.
Whisper harness: Python 3.14.8 standard library, with no Python dependencies
installed. The optional Gemma environment is described separately below.
Installed Homebrew whisper.cpp **1.9.4**, Metal/Accelerate, four CPU threads,
one process at a time. CLI executable SHA256:
`13650fc8ffaaa4e637c6951f7d2e492916877e70bd1b7a266fbfd0bdc597719e`.
That hashes the executable, not all dynamically linked GGML/Metal libraries.

All variants use English, beam size/best-of 5, temperature 0, fallback disabled,
no external VAD, no DTW, fresh CLI process per excerpt, and
`-ml 1 -sow -ojf -otxt` for approximate word-segment output. Metal is enabled;
Core ML/ANE is not configured. Plain and prompted variants otherwise match.
The prompt is a generic style example, not the reference transcript:
`Um, uh, well, I, I mean, you know, like, sort of.`

Prompt sensitivity was added after observing missing fillers in plain runs;
these are **development-set exploratory results**, not a preregistered holdout.
Repeated local runs produced the same text scores. The timing table records
the final serial run, with filesystem/GPU caches warmed by earlier runs.
Wall time includes process start/model loading; download time is excluded.
Peak process RSS from macOS `time -l` is not total unified/GPU memory or a
minimum-RAM claim. Short-clip throughput is not extrapolated to one-hour latency.

### Measured recognition results

| Weights / style | S / D / I | WER | Exact fillers retained | Exact filler precision | Speech wall time | Max process RSS |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| tiny.en / plain | 35 / 42 / 4 | 28.52% | 0/29 | N/A | 1.479 s | 260.0 MiB |
| base.en / plain | 25 / 34 / 2 | 21.48% | 6/29 | 100% (6/6) | 1.773 s | 372.7 MiB |
| large-v3-turbo Q5_0 / plain | 15 / 38 / 3 | 19.72% | 0/29 | N/A | 2.974 s | 837.1 MiB |
| tiny.en / prompted | 32 / 7 / 10 | 17.25% | 28/29 | 84.85% (28/33) | 1.668 s | 277.8 MiB |
| base.en / prompted | 25 / 7 / 4 | 12.68% | 25/29 | 100% (25/25) | 1.880 s | 376.5 MiB |
| large-v3-turbo Q5_0 / prompted | 11 / 4 / 7 | **7.75%** | **28/29** | 100% (28/28) | 3.173 s | 840.3 MiB |

### Measured independent Gemma reproduction

On **the same seven WAVs and identical normalization/scorer**, the open
reader v2 produced **73 substitutions, 21 deletions and 5 insertions: 99/284 =
34.86% WER; 0/29 exact `um`/`uh` retained**. Its ten-second digital-silence
output was empty, an advantage on this one control. In the name excerpt it
produced "david andrey and craig"; the word-constrained lexicon does not solve
names merely by being large. Repetitions sometimes survived (e.g. "our our");
that does not establish general disfluency coverage.

This is the **independent replica, not the eg2.haku.sh app**. It is a faithful
invocation of the inspected extraction recipe and decoder: full local base
checkpoint, float32 CPU/SDPA audio features, six-layer reader, normalized
200,000-word table, learned blank/scale, greedy CTC, no language model,
punctuation model or prompt. We verified all model/code/config hashes,
confirmed filler vocabulary entries, and loaded the checkpoint with
`weights_only=True` through the upstream decoder. Feature extraction uses
`get_audio_features(...).pooler_output` valid rows, not pooled utterance
embeddings. Each sample is below the extractor's 30-second cap.

Optional isolated environment: Python 3.14.8, PyTorch 2.14.1, Transformers
5.19.0, NumPy 2.5.3; four intra-op CPU threads, one inter-op thread. Inference
sets Hub/Transformers offline mode and `local_files_only=True`; only a separate
explicit preparation stage downloads public pinned assets. No remote model
code is requested. This is configured local inference, not a packet-capture
privacy audit.

The repeated conversational run reproduced all text scores. Its speech feature
extraction + decoding took **4.044 seconds** with the model already loaded;
imports/model initialization took **5.215 seconds**, excluding artifact-hash
verification and downloads. Peak whole-process RSS was **5,502.4 MiB**.
These numbers load the full Python reference
model and word table: **not comparable throughput/memory rankings** against
per-excerpt Metal Whisper or the demo's optimized ANE app, and not an optimized
audio-tower-only implementation. Accuracy inputs/scoring are matched;
accelerators, model precision and process-lifetime timing are not.

As a separate pipeline sanity control, the same Gemma path recognized **17/17
words** of the 5.855-second LibriSpeech dev-clean utterance
`1272-128104-0000`, with a genuine public reference retrieved from the
[HF dummy subset](https://huggingface.co/datasets/hf-internal-testing/librispeech_asr_dummy)
and [LibriSpeech's CC BY 4.0 provenance](https://www.openslr.org/12).
LibriSpeech attribution: V. Panayotov, G. Chen, D. Povey and S. Khudanpur,
"Librispeech: an ASR corpus based on public domain audio books", ICASSP 2015.
That clean control is excluded from the conversational totals and has no filler
tokens; it does not establish conversational quality or reproduce the reader's
full published LibriSpeech scores. An initial attempt to stream a different
control from the large publisher archive was stopped after its download stalled;
the small public subset supplied the successful replacement. No score was
assigned to that aborted attempt.

These small-sample precision figures are **transcript-token matching**, not
safe-removal precision, confidence bounds or guarantees. Tiny's extra prompted
fillers illustrate why high recall alone is insufficient. All model families
still make errors. In the proper-name excerpt turbo preserved David/Andrew/Craig;
base rendered Andrew as "Angie". Three names are not a proper-name benchmark.

| Ten-second digital silence | Plain output | Prompted output |
| --- | --- | --- |
| tiny.en | `[BLANK_AUDIO]` | `[BLANK_AUDIO]` |
| base.en | `You` | `[BLANK_AUDIO]` |
| large-v3-turbo Q5_0 | `Thank you.` | `Thank you.` |
| Independent Gemma v2 (no prompt mechanism) | Empty | N/A |

This reproduces a real silent-input failure, consistent with OpenAI's
[hallucination warning](https://github.com/openai/whisper/blob/main/model-card.md).
One silence control neither estimates a hallucination rate nor tests room tone,
music, breaths or crosstalk.

### Timing is a separate, unresolved problem

The harness compares valid raw one-word CLI segment times to AMI's forced-aligned
times for text-matched words. Multiword segments, zero/invalid spans and missing
words are not interpolated into timing coverage. This is an **exploratory
timestamp proxy**, not independent hand-labelled acoustic truth or
`WWWordEvaluation` supported observations.

| Variant | Text-matched valid boundaries / 568 | Range of per-clip p95 proxy error |
| --- | ---: | ---: |
| tiny.en plain | 400 | 970-2,050 ms |
| base.en plain | 426 | 630-1,940 ms |
| turbo Q5_0 plain | 422 | 630-2,380 ms |
| tiny.en prompted | 466 | 550-2,620 ms |
| base.en prompted | 450 | 970-7,260 ms |
| turbo Q5_0 prompted | 530 | 700-1,770 ms |

These are not an overall p95 or a claim that all error belongs to the recognizer:
AMI's forced timing can itself span pauses, and repeated-word correspondence is
text aligned. They show that this raw timestamp path is **not qualified for
precise cuts**. DTW/Whisper attention alignment and a separate local forced
aligner remain candidates needing independent boundary truth. Forced alignment
cannot discover a filler absent from the transcript; it can also force a
hallucinated word onto real audio. Neither fixes text mistakes automatically.
The independent Gemma decoder returned **no word timestamps**; its text score
is not timestamp accuracy and it is absent from this proxy timing table.

## Preserving accepted timing and safe edits

Store recognition in immutable **source-time identity**, not in rendered or
already edited audio coordinates: source/revision, selected channel, occurrence,
recorder epoch, native sample rate, exact half-open source frame range, token ID,
model/decoder and transcript revision, and timing method/support state.
Resampled 16 kHz analysis times must map back through the exact decode/window
origin and sample-rate transform; a display millisecond is not source identity.

For a source with an accepted file-local adaptive correction, project within
each supported segment using the existing equation:

`aligned = segment.alignedStart + (sourceSeconds - segment.sourceStart) * segment.rateRatio`

`SourceTimingCorrection.alignedTime(at:)` currently uses half-open segment
membership. A word/range projection must validate **the entire interval**, not
just its two endpoints: split at actual supported segment boundaries, carry
their provenance, and refuse gaps or invalid exclusive-end lookups. The
correction's aligned coordinates already include reference placement; do not
apply the recorder map a second time. Sources without a correction use the
existing exact occurrence/epoch source-frame -> group-clock -> aligned map.

Keep independently measured, anchor-guided, quiet-derived and optional estimated
timing distinct. Quiet support is not proof of absent/retained speech; estimated
playback is not verified word timing. Do not invent timestamps or bridge
unsupported regions. An accepted-map revision makes old projections/candidates
stale; source-bound recognition may remain available, but linked timing must be
explicitly refreshed/reviewed under the current map.

Filler candidates should be **reviewable strikeouts**, not deleted text during
ASR or automatic cuts. Silence/pauses need local acoustic/VAD evidence plus
all-lane protection; a transcript gap is not silence. Preserve breaths,
meaningful "like"/"well", false starts, laughter and another speaker's speech
unless independently eligible and accepted. After approval, use one common
edit map, shared rounded output boundaries, protected fades and Undo/history
for all affected tracks. The existing
[cut policy](../../Packages/WaveWranglerKit/Sources/WWCutPolicy/CutPolicy.swift)
and [review contract](../m3/design/transcript-review-spec.md) remain unchanged.

## Reproduction and artifacts

Harness: [`scripts/asr-research/benchmark.py`](../../scripts/asr-research/benchmark.py);
scoring controls: [`test_benchmark.py`](../../scripts/asr-research/test_benchmark.py).
Requires Python 3.11+, macOS `/usr/bin/time`, and an already installed
`whisper-cli`. It does not install tools, open private files, upload audio,
modify an app model or write model/audio/output data into the repository.

Choose an external local artifact directory. `prepare` retrieves only the two
named public AMI inputs and verifies their SHA256. Download model bodies
separately from this exact converted-weight revision:
[`ggerganov/whisper.cpp@5359861c739e955e79d9a303bcbc70fb988958b1`](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1).
The script validates each body against the following pins before execution.

| File | Bytes | SHA256 |
| --- | ---: | --- |
| ggml-tiny.en.bin | 77,704,715 | `921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f` |
| ggml-base.en.bin | 147,964,211 | `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002` |
| ggml-large-v3-turbo-q5_0.bin | 574,041,195 | `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` |

```bash
source "$HOME/.shell/exports-core.sh"
# Set ARTIFACTS to an external local directory, not the repository.
python3 scripts/asr-research/benchmark.py prepare --artifacts "$ARTIFACTS"
REV=5359861c739e955e79d9a303bcbc70fb988958b1
for MODEL in tiny.en base.en large-v3-turbo-q5_0; do
  curl --fail --location \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/$REV/ggml-$MODEL.bin" \
    -o "$ARTIFACTS/downloads/ggml-$MODEL.bin"
  python3 scripts/asr-research/benchmark.py run --artifacts "$ARTIFACTS" --model "$MODEL"
  python3 scripts/asr-research/benchmark.py score --artifacts "$ARTIFACTS" --model "$MODEL"
  python3 scripts/asr-research/benchmark.py run --artifacts "$ARTIFACTS" --model "$MODEL" --prompted
  python3 scripts/asr-research/benchmark.py score --artifacts "$ARTIFACTS" --model "$MODEL" --prompted
done
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/asr-research -v
```

Local session artifacts are under `files/asr/`: original public downloads,
`manifest.json` with source frames/annotations/clip hashes, cropped WAVs, and
per-variant `runs/*/{measurements,scores}.json`, raw CLI JSON/TXT and diagnostics.
They remain outside Git. The harness and this report are the persistent
research deliverables; no model/audio/raw output is committed.

For the **optional independent Gemma** experiment, use the additional runner
[`gemma_reproduction.py`](../../scripts/asr-research/gemma_reproduction.py).
It verifies pinned code/config/vocabulary/weights and downloads approximately
1.9 GB into the external artifact directory. It does not install or launch
either Mac app. The optional clean control also requires an installed `ffmpeg`
to decode its pinned FLAC. The separate dependency manifest does not alter Swift/app
dependencies. Load existing user Python configuration before restoring it;
do not override configured package indexes:

```bash
source "$HOME/.shell/exports-core.sh"
source "$HOME/.shell/exports.sh"
uv venv --python /opt/homebrew/bin/python3 "$ARTIFACTS/venv"
uv pip install --python "$ARTIFACTS/venv/bin/python" \
  -r scripts/asr-research/requirements-gemma.txt
python3 scripts/asr-research/gemma_reproduction.py prepare --artifacts "$ARTIFACTS"
PYTHONDONTWRITEBYTECODE=1 "$ARTIFACTS/venv/bin/python" \
  scripts/asr-research/gemma_reproduction.py run --artifacts "$ARTIFACTS"
PYTHONDONTWRITEBYTECODE=1 "$ARTIFACTS/venv/bin/python" \
  scripts/asr-research/gemma_reproduction.py calibrate --artifacts "$ARTIFACTS"
```

Results are in `runs/gemma-independent-v2-cpu/scores.json` and per-clip TXT,
with downloaded assets in `gemma/` and the complete dependency freeze in
`gemma-dependencies.txt`. The base safetensors SHA256 is
`197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79`;
reader weights:
`d605f6fba8687497be6b5fd717ea6c51beaee5d5f69c30a64225da96ebe0d8c2`;
word table:
`b2d0b13cc70c492f1444b8a42deab437d25254eac47d752d777d27b65377faa8`.
All other exact pins are in the runner. These are downloaded-body verifications,
not metadata-only expected hashes.
The optional clean-control action validates the public row ID/text and FLAC
SHA256 `4e25e22555cd16e90edb0a3b49fdcf1fe652b2a1250ab643634db33895c75b41`,
then records a separate `calibration-manifest.json` and
`runs/gemma-independent-v2-cpu-calibration/scores.json`. Expired HF audio URLs
are refreshed from the public rows endpoint; changed content fails hash checks.

Whisper code and original weights have an [MIT license](https://github.com/openai/whisper#license);
the [cpp runtime](https://github.com/ggml-org/whisper.cpp/tree/v1.9.4)
also declares MIT. Converted-artifact provenance, distribution notices and
bundled dependencies still need release review; this experiment is not blanket
redistribution clearance.
