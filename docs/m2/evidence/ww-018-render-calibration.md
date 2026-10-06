# WW-018 evidence: candidate group renderer, calibration and `m2-freeze-render`

**Status: CANDIDATE, calibrated, gates frozen. Holdout NOT run. Not qualified. Listening BLOCKED.**

**Scope.** `WWRender` (Packages/WaveWranglerKit) is a pure module: Foundation, `WWCore` and `WWTimeMap` only.
It has no file, URL, decoder or content API. `RenderPurityTests` checks this, and the repo-wide
`noOtherModuleOrTheAppDecodes` scan covers it. `GroupRenderer.render` takes:
- a `RenderRequest`: a `GroupTimeMap`, an output rate G, output frames, ordered output channels and per-occurrence
  input-asset versions;
- a caller-owned `RenderSampleProvider` that returns plain decoded `Float` buffers;
- a sink factory.

Each output channel names an occurrence, a decoded channel and a `Knowledge<Int>` stated channel. The stated
channel comes from #63 and is an input only; app integration waits for #63. The renderer streams bounded chunks
(`outputChunkFrames`, default 4096) in a `@concurrent` async function, so it never runs on the main actor (`rendersOffTheMainThread`). It holds at most one
tap-reach window per occurrence, and it abandons the sink on cancellation, provider failure or sink failure.

**Conventions.** All of these are consumed from `WWTimeMap`; `ClockConventions.swift` is the sign source.
- Each output frame k inverts the map exactly: `x(k) = F·((k/G − b)/a − e)`. That gives `F/(a·G)` source frames
  per output frame, so the documented ratio is `a·Fout/Fin`. The clock pitch factor `1/a` is recorded per run.
- There is no time-stretch parameter, and no gain, mix, downmix or proxy input. The request types cannot express
  them; a test checks every field.
- The explicit delay is the manifest's `outputStartFrame`. Gaps, unsupported epochs and frames outside coverage
  render as explicit `+0.0` padding runs with typed reasons, and no frame inside them is requested.
- Rounding is common to the group: one exact `Int128` phase per output frame per occurrence, shared by every
  channel. Taps never cross a span boundary; out-of-span taps read zero.
- A unit step at an integer position is a bit-exact copy. A unit step at a fractional position is interpolated.

The manifest records:
- `RenderVersions.renderer` 1 and `outputAssetFormat` 1;
- the `RenderRecipe` (version 1);
- the group and reference;
- per occurrence, the input asset version and every run (epoch, span, segment, ratio, pitch, first exact position).

**Renderer (candidate).** `RenderRecipe.m2Candidate` is a self-written Kaiser-windowed sinc:
- 32 taps per side;
- passband edge 0.8, stopband edge 1.0, β 9.6;
- a 2048-phase table with linear interpolation, each weight set normalised to unit DC gain;
- taps widened by `1/step` when downsampling, up to 64× decimation.

It replaces the 64-tap Blackman candidate in `docs/research/waveform-clock-render-readiness.md`. That candidate
was only ever exercised on 6-channel 16-bit WAV at 12/16 kHz, and so is this one beyond the fixtures below.

**Fixture `M2-RENDER-001`.** It is synthetic only; the generator is in `RenderCalibrationTests.swift`. Seed =
SHA-256(`ww-m2-fixture|v1|M2-RENDER-001|<split>|<i>`). Each case is one 6-channel occurrence on one affine epoch.

There are 8 strata:
- 48k→48k, 44.1k→48k, 16k→48k, 48k→16k, 96k→48k and 12k→48k, each at ±1000 ppm;
- 48k→44.1k at a≈1.02;
- 44.1k→48k at a≈0.98.

The offsets b and e are seeded fractions. Each case carries:
- one passband tone per channel, at 0.02–0.8 of the lower Nyquist;
- stopband tones whenever the output Nyquist is lower than the input Nyquist;
- a common impulse with seeded per-channel signs, for skew and inversion;
- a per-channel unique impulse, for swaps;
- one isolated −1 dBFS noise channel next to five silent ones.

One fixed multi-span `MixedGroup` case is added per split. It has a segment kink, a gap restart, an unsupported
epoch, and 44.1 kHz + 48 kHz occurrences with two cross-occurrence skew pairs. **Truth** is the WWTimeMap
forward/inverse, never the render plan. Gates fail on NaN or missing evidence.

**Calibration** (16 cases + multi-span, 466 records, [`ww-018/calibration.jsonl`](ww-018/calibration.jsonl)).
The records are SHA-256 `f8a1ee31…7889`, byte-identical across three separate test processes. File order is
canonical and total (case, kind, channel, then the encoded line), so task completion order and Dictionary order
cannot change it; `recordOrderIsDeterministic` guards this. (The first committed file, `5670f81a…be98`, held the
same 466 records, but the two multi-span skew records could swap between processes.) The split is CPU-bound, so it
runs alone in `scripts/test.sh` (`WW_RENDER_CALIBRATION=1`, after the parallel package pass). The script fails if
the test is skipped. In the parallel pass it would starve the time-limited WWSources suites on CI's small runner.
Every gate passes:

| Gate (verbatim) | Limit | Worst calibration value |
| --- | --- | --- |
| Landmarks | ≤1 output frame | 0.169 frames (204 landmarks) |
| Passband | ±0.1 dB to 80% of lower Nyquist | 0.000146 dB (96 tones; worst 44.1k→48k a≈0.98) |
| Alias | ≤−80 dBc | −92.97 dBc stopband (36 tones, 48k→44.1k a≈1.02); in-band residual −109.24 dBc |
| Interchannel skew | ≤1 output frame | 0.0537 frames (multi-span); single-span ≤2.8e-6 |
| Inversions/swaps | 0 | 0 |
| Inactive output | ≤−80 dBFS | exact zero (−∞ dBFS) in all 80 inactive channels |
| Phase tolerance | calibrated → **frozen 0.001°** | 2.76e-6° |
| Family peak | ≤1 GiB | 38.4 MiB resident (see timing) |
| License/notices | native or self-written only | resolved: all code self-written; no package dependencies, no third-party code, no notices needed |
| Listening (≥3 consented listeners, ≤5% objectionable) | — | **BLOCKED — not granted, not measured, not passed** |

The phase tolerance is the worst value ×10, floored at 0.001° (the Float32 quantisation floor: 0.001° at 0.4
cycles per frame is 7e-6 frames), on a 1-2-5 series.

**Informational, not a gate:** the active channel peaks at up to +3.06 dBFS after rendering. That is inter-sample
overshoot of −1 dBFS white noise. Downstream export must not assume the output stays below full scale.

**Timing / memory.** `WW_TIMING_TESTS=1` runs `renderFamilyPeakAndThroughput` serially in `scripts/test.sh`. It
renders 6 channels for 60 s at 48 kHz with a = 1.0001, through a discarding sink
([`ww-018/timing.txt`](ww-018/timing.txt)). Results:
- 704 chunks;
- peak window 4159 frames;
- renderer working set 198,632 bytes (asserted ≤1 MiB);
- resident peak 38.4 MiB (asserted ≤1 GiB);
- 34.8 s wall in a Debug build (1.7× real time).

Debug throughput only; no Release benchmark is claimed.

**Freeze record.** [`m2-freeze-render.json`](../fixtures/m2-freeze-render.json) is dated 2026-10-06 and listed in
the [M2 fixture registry](../fixtures/m2-fixture-registry.json). It holds the fixture, recipe, truth,
measurement, gates, split counts, calibration summary and host:
- splits: 16 calibration and 48 holdout cases, each plus the multi-span case;
- host: macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4, M5 Max with 18 cores, 128 GiB.

It also pins the generator and renderer git tree IDs: `WWRenderTests` `ef0617bd…` and `WWRender` `94604633…`.
`RenderFreezeTests` (always on) fails if the gates, recipe, versions, split counts, registry entry or either
pinned tree drift from the record.
It takes effect at this PR's merge commit. Disclosed: the multi-span case is fixed, so it is the same in both
splits and is not held out.

**Holdout: not run.** It runs once on a clean commit after merge, with `WW_M2_RENDER_HOLDOUT=1`. Every case and
gate is reported. Nothing is tuned after the freeze.

**Robustness (tested, typed errors, nothing read on refusal):**
- empty, oversized or out-of-envelope output ranges;
- empty, duplicate or unknown channel routes, or a mismatched stated channel;
- missing, duplicate, extra or blank input assets;
- decimation beyond the recipe;
- `Int128` overflow in run numerators;
- unsafe or undecodable recipes;
- wrong provider shape or non-finite input;
- provider, sink or sink-creation failure, and cancellation (the sink is abandoned);
- a planner/map disagreement, caught by self-check.

Output is chunk-size invariant across 64–65,536 frames. Strict-pool runs pass: `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1
swift test --filter WWRenderTests`, and the same with `WW_RENDER_CALIBRATION=1` for the calibration split.

**Mutation checks** (66 mutants; one source edit each; `swift test --filter WWRenderTests` or
`noOtherModuleOrTheAppDecodes`): **60 killed, 6 survived, all 6 equivalent.**
- **Killed:** gain, polarity, channel swaps (filter and copy paths), cross-channel leak, one-frame delay, phase
  offset, missing anti-alias scaling, unwidened downsampling taps, non-zero padding, out-of-span requests, shape
  and finiteness checks, cancellation, sink abandonment, identity fast path, every request/asset/route/envelope
  validation, all five overflow flags, every recipe guard, the purity and repo-wide scans, and every gate check
  (limits, the passband fraction filter, NaN and missing evidence).
- **Killed after a new test:** "fractional unit ratio treated as copy" survived the first pass. That exposed a test
  gap, now closed by `unitRatioWithFractionalDelayInterpolates`.
- **Calibration-only kills:** G07 (phase offset), G08 (no anti-alias scaling) and P24 (unwidened taps) are
  killed only by the calibration split. They were rerun with `WW_RENDER_CALIBRATION=1`, which is what CI runs, and
  stay killed.
- **Manual checks:** never dropping consumed window frames fails `workingSetIsBounded`, which now renders 36,000
  frames rather than 190,000. Removing `WW_RENDER_CALIBRATION=1` from the calibration pass makes `scripts/test.sh`
  fail rather than skip silently. Freeze guards: changing a `RenderGates` value, the recipe's Kaiser beta, or the
  registry's `m2-freeze-render` entry each fails `RenderFreezeTests` (and any source or test edit fails the
  pinned-tree check). Dropping the encoded-line tiebreaker from the canonical record order fails
  `recordOrderIsDeterministic` (reversed and shuffled inputs). Reverting the multi-span skew loop to Dictionary
  iteration survives in-process (one process sees one hash order); for the records file it is equivalent, because
  the canonical order is total. The sorted loop stays as defence in depth, and the cross-process hash check above
  covers it.
- **Equivalent survivors:**
  - G09/G10 (tap clamp to span end/start): needs are clipped to the span, so the window never extends past it;
    defence in depth.
  - G20 (backward-window guard): needs are monotone, so it is unreachable.
  - P15–P18 (planner self-checks against the map: start, end, run overlap, padding uniformity): redundant while
    the planner is correct. P14 plants an off-by-one planner bug, which the self-checks catch (21 tests fail).

**Not claimed.**
- Not qualified: the holdout is not run.
- Listening is BLOCKED.
- No real recordings were used.
- No decode-envelope widening.
- No Release benchmark.
- Spectral evidence covers synthetic tones and impulses only; there is no music or speech material.
- No persistence or job invalidation (WW-020), UI or export.

Refs #13 #18.
