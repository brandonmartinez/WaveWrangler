# M2 local-episode validation (headless, user-approved disposable copy)

Refs #45 #15 #24 #13 #18. One run, 2026-10-06 (UTC), on the user-provided disposable local episode copy
(path withheld), with the user's consent as relayed by the M2 coordinator. The run was local only and
headless: no GUI, no app launch, no network, no transcription or speech analysis. Sources are named
S01..S16 in a stable order: audio items by size descending (ties broken by SHA-256), then non-audio items.
No path, file name or content appears here or in the harness.

## Run record

- **Host:** Apple M5 Max, 18 cores, 128 GB, macOS 27.0.1 (26A434). Apple Swift 6.4 (swiftlang-6.4.0.34.1).
  Package tools version unchanged (6.2).
- **Code:** base `c9709e7` plus harness commit `d2b91b8`. The harness ran exactly as committed
  (`Packages/WaveWranglerKit/Tests/WWLocalEpisodeValidationTests/`). Pipeline versions: decode envelope v1,
  estimator `ww-align-estimate/1`, renderer v1, recipe v1.
- **Command** (run alone, nothing else running in parallel; `<withheld>` is the approved folder; the
  scratch directory came from `mktemp -d` under `$TMPDIR`, outside the repository and any synced folder):

  ```sh
  cd Packages/WaveWranglerKit
  WW_LOCAL_EPISODE_DIR=<withheld> WW_LOCAL_SCRATCH_DIR="$(mktemp -d)" \
    swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter LocalEpisodeValidationTests
  ```

  `-DDEBUG` is there only so that the other test targets, which use `#if DEBUG` gateway test hooks, compile
  in release. Those hooks default to nil, so the gateway took its production path.
- **Result:** the suite passed in 44.0 s (51 s including the build), with **findings: none**. The harness
  is skipped whenever `WW_LOCAL_EPISODE_DIR` is unset, so CI never runs it.

## Sources (decode through the WWDecode gateway)

Listing was metadata only: 16 items, 2 subdirectories, nothing hidden, no links, no unreadable entries.
13 items are audio by content type; 3 are non-audio and were never opened.

| S | Container / sample format | Rate | Ch | Duration | Decode verdict |
|---|---|---|---|---|---|
| S01–S06 | WAVE, float32 LE | 48 kHz | 2 | 74.5 min | supported, exact in float32 |
| S07 | AIFF, int24 BE | 48 kHz | 2 | 74.4 min | supported, exact |
| S08–S09 | WAVE, float32 LE | 48 kHz | 1 | 74.5 min | supported, exact |
| S10 | AIFF, int24 BE | 48 kHz | 1 | 74.4 min | supported, exact |
| S11 | WAVE, int24 LE | 48 kHz | 1 | 73.8 min | supported, exact |
| S12 | WAVE, int16 LE | 44.1 kHz | 1 | 71.7 min | supported, exact |
| S13 | MPEG audio (`MPG3`) | — | — | — | typed refusal `unsupported(container("MPG3"))`. **Expected**: MP3 is outside envelope v1 ([ww-050](ww-050-decode-envelope.md)) |
| S14–S16 | non-audio | — | — | — | not opened (metadata only) |

Every supported source reported codec lpcm, priming 0, remainder 0, no packet table, a matching extension
and no frames discarded. Each decoded frame count equals its declared valid frames. Decode ran at
1.3–3.0 GB/s (about 6,000–14,000× real time) with a warm page cache, because the hashing pass had just read
the files. No sink callback ran on the main thread.

Levels, as an aggregate statistic only: S03–S06 and S08 have a whole-file peak below 1e-4 (silent or
near-silent tracks); S10 and S11 reach full scale.

## Recorder groups (metadata only: identical rate and identical valid frame count)

- **G1:** S01–S06, S08, S09. 14 channels.
- **G2:** S07, S10. 3 channels.
- **G3:** S11.
- **G4:** S12.

No two groups' durations are within 1 s of each other. These groups are proposals from metadata, not
identity claims.

## Estimator observations (no clock truth: observations, not accuracy claims)

There were 18 requests on in-memory 8 kHz (S12: 8.82 kHz) mono analysis mixes. The mixes were never
written. Requests ran concurrently and off the main thread, taking 18.8 s wall in total.

- **Cross-group, stage 1** (6 pairs; the longer group is the reference; ±600 s; full overlap): **all
  abstained**.
  - G1←G3 and G3←G4: 0 eligible windows (weak/periodic).
  - G1←G2 and G2←G3: 2 of 16 eligible (weak).
  - G1←G4 and G2←G4: 3 of 16 eligible (periodic). Median peak scores were 0.99 and 0.63.
- **Cross-group, stage 2** (re-run once, narrow ±5 s around the stage-1 median of the eligible windows,
  with the implied overlap declared):
  - G1←G4 abstained (periodic). 5 of 16 windows were eligible, an eligible fraction of 0.31 against a gate
    of 0.6. Those windows agree within about 10 ms.
  - G2←G4 abstained (silent), with 2 of 16 eligible.
- **Within-group** (each member vs the mix of the others, ±5 s): **all 10 abstained**, mostly silent
  windows. In G1, S01 and S09 each had 4 of 16 windows eligible, at −0.1 ms and +0.1 ms.

There were no proposals, so there was nothing to approve or reject, and the time-map acceptance path was
not exercised on real material. The estimator made no proposal on an unrelated pair or a same-clock
member. Scores are evidence measures, not probabilities. Abstentions on this material reflect the coverage
gate and the content (long silent or periodic stretches); they do not establish the estimator's accuracy.

## Render invariants (WWRender, channel-consistent)

- **Setup:** group G1, all 14 channels from 8 members, 30.0 s (1,440,000 frames) at 48 kHz. The input was
  an in-memory 36 s slice per member.
  - The group map was a manual numeric entry of +10 ppm and a 0.37-frame offset, applied identically to
    every channel.
  - The recipe was `.m2Candidate`.
  - The output went to the scratch directory as one interleaved float32 file of 80,640,000 bytes.
- **Channel count and shape:** OK in memory, in the manifest and in the written file. Read-back matches.
- **Exact time-map round trip** (frame → aligned time → frame): 40/40 landmark frames exact.
- **Interchannel skew** (normalised cross-correlation per 4096-frame block, against the mapped position):
  - Maximum skew was **0.0009 output frames**, against a gate of 1 frame.
  - The maximum |measured − mapped source position| was 0.065 frames.
  - Only 11 blocks had at least 2 active channels (29 active channel-blocks), because most of G1's
    channels are near-silent.
- **Throughput and memory:**
  - Throughput was 5.8× real time (3.86 M channel-frames/s).
  - Renderer peak working set was 0.46 MB, with a peak window of 4,159 frames.
  - Process footprint went from 8,480 MB to 5,135 MB across the render.
  - Process peak RSS for the whole run was 20.6 GB. This was dominated by the concurrent ±600 s estimator
    requests and the 12 resident analysis buffers, not by the renderer.
- No render sink callback ran on the main thread.

## Source immutability

Size, mtime, ctime and inode (`lstat`) were snapshotted for all 16 items, plus SHA-256 for the 13 audio
items (15.00 GB, plain read-only hashing of the approved folder only), before and after the run.
**16/16 were unchanged.** Audio was opened for decoding only through the WWDecode gateway.

## Temporary data

The only derived file was the render asset, written in the `mktemp -d` scratch directory. The directory was
deleted with `rm -rf` immediately after the run, and a check confirmed it no longer existed. Analysis
buffers were never written. Nothing derived was kept or committed.

## What this does NOT show

- **Alignment accuracy or correctness on real material.** There is no clock truth; every estimator outcome
  above is an observation, and none was a proposal.
- **The time-map acceptance path for a real acoustic proposal.** No proposal occurred.
- **Cold-cache decode throughput.**
- **Formats beyond those listed.** MP3 remains outside the decode envelope.
- **Product or UI behaviour.** There was no app, GUI or persistence, and no transcription or speech
  analysis, which belongs to M3.
- **Any other episode, recorder or host.**
