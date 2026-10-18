# Pause-preferred transcription and word-timing limits

Implemented/measured 2026-10-18 on the same M5 Max/macOS 27.0.1/Xcode 27 host as the
[acceleration comparison](apple-silicon-transcription.md), starting at local `370d41f`.
No private recording or saved private transcript was inspected, transcribed or uploaded.

## Shipped policy

Recognition prefers a sustained pause near the planned boundary, not a grammatical sentence end.
All coordinates are half-open 48 kHz aligned frame ranges:

- Plan a maximum 28-second core, with up to one second of context on each side, clipped to In/Out.
  Every actual Whisper input, **including context**, is at most 1,440,000 frames / 30 seconds.
- Analyze the final four core seconds plus available right context in 10 ms RMS hops.
  A quiet run must last at least **300 ms** and stay below both **-50 dBFS RMS** and
  **20 dB below the local 90th-percentile RMS**. Uniformly quiet nonzero input does not pass
  the relative gate merely because it is quiet. Exact zero does; the existing inference shortcut remains.
- Prefer the latest qualifying run's center, clamped to the planned maximum; otherwise use that
  maximum. The final core is not subdivided. No core exceeds 28 seconds or shrinks below 24 seconds
  except the final remainder.
- Retain left/right context. Re-render overlap next time instead of caching unbounded PCM.
  The candidate is rendered in the existing <=5-second aligned pieces, inside the admitted lane.
  Only the selected prefix plus right context goes to inference; omitted candidate suffix frames
  are covered by subsequent cores, **not removed from the episode**.

This is an energy heuristic, not VAD or a phonetic/sentence detector. Noise may mask pauses;
a quiet word or breath may resemble one. Context mitigates boundary risk but does not guarantee
complete sentences or complete recognition. No recognized text, punctuation or fillers are used
to select boundaries. No silence removal, accepted timing change, source retiming, export change,
new dependency, new control or automatic cut was added.

Every aligned frame belongs to exactly one consecutive core. Timed word ownership uses the raw
window-relative midpoint against relative core frames, avoiding large/fractional timeline subtraction.
Ownership is not cross-window forced alignment: inaccurate native times can still cause word
omissions or duplicates. Untimed recognized text is retained. Source anchors still come from
`CleanupSpeakerLane.sourceRange` and the original source identity/accepted affine or adaptive map.

Audio/model allocation stays inside existing shared admission. The planner stores only a few
coordinates and <=500 RMS values, reuses the <=30-second candidate PCM, and adds no full-recording
prepass. CPU/Metal/Automatic, captured threads, worker/memory limits, two Metal slots, cancellation,
source reverification, deterministic all-speaker publication and undo remain unchanged.
Progress advances by unique completed core frames, not context or candidate rendering. Chunk count
is genuinely unknown until the final core; the UI shows a current chunk without a guessed total.

The saved production recipe appends:

`pause-v1-core28-context1-lookback4-rms10ms-min300ms-cap50dB-relative20dB`

to the captured model/hash/backend/thread/verbatim recipe. Raw native timing remains the existing
token-bounds-v1 heuristic. Existing transcripts are not rewritten.

## Public/generated comparisons and threshold choice

Public input: AMI ES2002a speaker B, headset 1, AMI Consortium / University of Edinburgh,
**CC BY 4.0**, [AMI Corpus](https://groups.inf.ed.ac.uk/ami/corpus/).
The existing verified source/annotation artifacts are reused, not new private inputs:

| Input | SHA-256 |
| --- | --- |
| `ES2002a.Headset-1.wav` | `285ed5b5eaa4f871cc146900d0cf87487ca757aa57a7062def2eb49feaabc23d` |
| `ami_public_manual_1.6.2.zip` | `b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d` |

Two contiguous excerpts extend previously selected intervals, independently of recognition:
`[55.73,165.91)` and `[394.62,487.21)`: **202.77 seconds, 413 reference words,
37 exact reference `um`/`uh`**. Manual text is genuine; word times are automatically
forced-aligned, **not hand-validated phoneme/cut boundaries**. This is still one meeting/channel,
limited overlap, not an independent diverse holdout. Non-B backchannels may count as insertions.

The actual `LocalWhisper` 48k->16k adapter ran pinned Base English and Turbo Q5_0 on Metal,
four requested threads, one admitted worker, fresh native context per window. Bounded source
slices are expanded 16k->48k by repetition before production resampling. This isolates chunking
and ownership; it is not a full-episode aligned-renderer or UI performance benchmark.
Fixed reference: 28-second cores, same context, prompt, backend and ownership.

| Minimum pause | Base WER / exact fillers | Turbo WER / exact fillers |
| --- | --- | --- |
| Fixed reference | 17.43% / 30 of 37 | 11.62% / 34 of 37 |
| **300 ms (shipped)** | **16.22% / 30** | **14.53% / 34** |
| 400 / 600 ms | 19.37% / 31 | 14.04% / 33 |
| 800 ms | 18.64% / 29 | 17.68% / 27 |
| 1,000 ms | 17.92% / 30 | 13.56% / 32 |

300 ms preserved the fixed reference's exact filler matches in both models and avoided the larger
Base error/filler losses of longer thresholds. Generated 200/290 ms dips are rejected, while
300/500/600/800/1,000 ms low-energy pauses are detected; continuous/quiet/noisy controls fall back.
The four-second lookback limits earlier splits to a small part of each core, rather than chasing
arbitrarily distant silence. These are conservative initial choices, **not established optimal
thresholds**. In particular, **Turbo WER worsened by 2.91 percentage points** despite unchanged exact
filler retention. No overall accuracy gain is claimed; threshold selection used this small corpus.

Boundaries in excerpt-relative seconds:
fixed `[28,56,84]` for both; pause `[28,53.74,81.74,107.55]` and `[28,56,83.905]`.
The first excerpt needs one extra final window; every frame remains covered.

| Model / policy | Substitutions / deletions / insertions | Edge-near reference words / deletions / insertions |
| --- | --- | --- |
| Base fixed | 34 / 24 / 14 | 20 / 3 / 3 |
| Base pause | 35 / 19 / 13 | 18 / 1 / 1 |
| Turbo fixed | 14 / 8 / 26 | 20 / 2 / 5 |
| Turbo pause | 18 / 12 / 30 | 18 / 2 / 6 |

"Edge-near" means a midpoint within one second of that policy's interior core boundary.
These denominators differ when boundaries move; they are diagnostics, not a controlled accuracy
claim. Insertions include possible duplication, hallucination and other-speaker speech, not
verified duplicate words. The harness persists raw context segments and owned segments separately.

Candidate audio rendered: **214.770 s fixed / 220.755 s pause**, +2.79% (includes overlap and
discarded lookahead). Selected input lengths are independently asserted <=30 s.
RMS selection took about **1.2 ms total** across both excerpts; fixed planning about 0.01 ms.
One final run including bounded file reads/resampling/native inference: Base **3.61 / 3.61 s**,
Turbo **7.30 / 7.66 s**, fixed/pause. These cache-warm, sequential, single-round observations are
not cold latency, resource-envelope measurements or proof that aligned rendering costs the same.

## Reported early `um`: what is and is not improved

The user's listening report is credible evidence of a mismatch, but label text or a waveform peak
does not establish the true phonetic interval. No private case-specific diagnosis is claimed.
The code/control trace distinguishes:

1. **Native timing:** `CPUBridge.c` enables token timestamps and word splitting, but disables DTW.
   Vendored `whisper.cpp` interpolates unassigned token times by token voice lengths, then adjusts
   using local energy. These are not forced word/phoneme alignments. `LocalWhisper` preserves
   valid segment t0/t1 in hundredths of a second; invalid intervals become untimed, not invented.
2. **Resampling:** generated 100 ms bursts at 2.25, 14.375 and 28.75 s traverse the real 48k->16k
   converter. Onset/offset checks are within 3 ms, not seconds. This rules out a seconds-scale
   converter offset in that control, not every source format/adaptive rendering scenario.
3. **Mapping/storage:** synthetic hosted tests compare returned word intervals to
   `audioFrames.lowerBound / 48000 + rawTime`, then compare original source anchors to the accepted
   lane map. Fractional In/Out and moved pause boundaries preserve that mapping; no systematic
   early offset was found. Fixed and pause paths share it.
4. **Display:** `AudioTimelineWordLayout` starts each interval/label at the saved `alignedStart`,
   clips its duration to the viewport and changes rows, not horizontal anchoring, to avoid overlap.
   Text can extend beyond a short interval for readability. Existing rendered-coordinate tests
   exercise panning/zooming and assert the underlying saved interval independently of label width.

Actual word-boundary errors persist in public outputs. On the **same matched reference tokens**
under both policies:

| Model / policy | Common boundaries / p95 absolute error | Common timed fillers | Filler onset / offset p95 error | Mean signed filler onset |
| --- | --- | --- | --- | --- |
| Base fixed | 680 / 2.34 s | 26 | 2.34 / 3.72 s | -0.630 s |
| Base pause | 680 / 2.88 s | 26 | 3.26 / 3.45 s | -0.613 s |
| Turbo fixed | 752 / 1.90 s | 34 | 2.72 / 2.75 s | -0.364 s |
| Turbo pause | 752 / 1.85 s | 34 | 2.07 / 1.82 s | -0.332 s |

Negative signed onset is early. Repeated fillers make reference/hypothesis matching ambiguous,
and the forced-aligned reference itself is imperfect. These are proxies, not cut qualification.
Errors also occur away from chunk edges: all-matched interior-boundary p95 fixed/pause is
**2.34 / 2.93 s Base**, **1.94 / 1.88 s Turbo**. Pause detection is not an adequate timing fix.

A separate **10-second fixed-core timing candidate**, same one-second context, produced WER
**35.11% Base / 17.92% Turbo**, retaining **22 / 28** exact fillers versus **30 / 34** on fixed28.
It required 241.95 s candidate input and about 6.91 / 12.92 s wall time. It was **not shipped**.
Although some Turbo filler onset errors shrink, the changed matched subset and recognition losses
do not justify presenting it as a reliable refinement.

A genuine alignment/refinement pass is a future qualification task, not amplitude snapping.
The pinned engine has experimental DTW token `t_dtw` support, but it is not the currently exported
word interval, lacks a Turbo-specific preset in this version, and needs model-specific head,
memory/backend, cancellation and word aggregation validation. No unverified DTW or new alignment
dependency was enabled. No reliable new phonetic refinement was established here. Timings remain
review-only; saved transcripts are untouched and automatic slicing remains disabled.

## Reproduction and verification

Let `R` be the existing external public artifact directory containing `downloads/` and the
verified inputs/models described in the acceleration report. All outputs stay outside Git:

```bash
source "$HOME/.shell/exports-core.sh"
python3 scripts/asr-research/chunking.py prepare --artifacts "$R"
WW_ASR_CHUNKING_FIXTURES="$R" SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
  swift test -c release -Xswiftc -DDEBUG --package-path Packages/WaveWranglerKit \
  --scratch-path .build/swiftpm --jobs 4 --filter TranscriptionChunkingCorpusTests
WW_ASR_CHUNKING_FIXTURES="$R" WW_ASR_CHUNKING_SWEEP=1 \
  SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
  swift test -c release -Xswiftc -DDEBUG --package-path Packages/WaveWranglerKit \
  --scratch-path .build/swiftpm --jobs 4 --filter TranscriptionChunkingCorpusTests
python3 scripts/asr-research/chunking.py score --artifacts "$R"
python3 -m unittest discover -s scripts/asr-research -p 'test_*.py'
```

`chunking/` retains manifest, captured recipe, raw window/core/candidate ranges and segments,
owned segments, per-policy metrics and same-reference timing comparison. Model verification
still uses the production hash-pinned loader. No network inference or dependency installation.

Focused package checks cover generated thresholds, quiet/noisy/zero/continuous input, negative
and fractional origins, final one-frame cores, exact coverage/context/max length, cancellation,
relative midpoint ownership, resampling, and existing source/resource/worker policy.
Actual Base/Turbo CPU and Metal controls retain same-backend concurrent text/times and drain
cancellation. Synthetic hosted checks exercise moved pause boundaries, returned source anchors,
In/Out, preserved fillers/untimed text, progress, all-speaker failure/cancellation and timeline
coordinates. Tests build only the separate Debug host under `.build/DerivedData`; the user's
Release app bundle is not overwritten.
