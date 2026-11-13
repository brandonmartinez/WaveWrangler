# Audio processing

Rendering consumes authorized source buffers and explicit timing/processing
recipes. Waveform appearance, acoustic proposals and cached PCM never grant
permission or redefine clocks. See [program timeline](program-timeline.md)
for exact coordinate and clip-edit rules.

## Source, aligned and production audio

**Untimed original-source Solo** uses original source time. Its identity map
is ephemeral: it neither activates accepted timing nor applies cuts and cannot
be persisted or used as a production recipe.

**Source Audition** compares currently admitted recording channels using
explicit listening choices. Speaker mutes, boundaries and cuts apply where
that path specifies them. It is not the final mix.

**Production Mix** consumes confirmed Primaries, supplemental clips, active
common cuts and insertions, speaker mutes, production bounds and the canonical
mixer. It does not inherit transient Solo/Mute or display-layout choices.
Diagnostic Show Cut expansion cannot supply its inverse map or reintroduce
removed dialogue.

`WWRender` performs pure affine sample-rate conversion from exact map inverses,
not pitch-preserving stretch. It receives decoded buffers, not URLs, and applies
no gain or mixing. Keep `-O` enabled for WWRender even in Debug: unoptimized
drift correction can fall behind real-time production despite a fast AU callback.
Changes to output samples or asset representation require renderer/recipe/format
version changes and cache invalidation, not silent reuse of historical keys.

Adaptive rendering uses one multichannel native TimePitch at zero pitch, retaining
channel relationships. Processing is bounded and region-anchored (12-second
regions plus context/crossfades), with five-second versioned cache tiles.
Estimated timing remains visibly distinguishable from measured support.
See [automatic alignment](automatic-alignment.md) for admission/provenance.

## Formats, routing and effects

The mixer uses 48 kHz planar Float32: mono speaker routes, stereo asset tracks
and stereo master. Unknown multichannel geometry refuses instead of choosing
channel zero, using an automatic Backup, or inventing a downmix from count alone.
Native effects receive PCM and declared layouts, never a source URL.

Speaker processing is recording input gain once, inserts, parallel-path delay
compensation, then fader/equal-power pan. Clip processing uses absolute source
conversion, occurrence envelope, stereo track summation, inserts, compensation
and balance. Speaker/asset paths sum into master inserts and master gain.
Do not divide by route count or normalize overlapping clips.

Live gain/pan/mute ramps are 480 frames (10 ms). Finite overunity output remains
overunity; meters report sample peak/RMS/headroom, not integrated LUFS or true
peak. Delivery conversion/clipping policy belongs in
[export](export-codecs.md), not the production mixer.

Admit compatible `aufx`/`aumf` units only, disable unused auxiliary inputs and
validate actual bus formats. Missing/incompatible/failed units refuse with slot
identity; do not silently substitute or bypass them.
Loads have a 30-second bound and cancellation/late-instance guards.
Requested out-of-process instantiation is not a guaranteed security boundary.
Never lower sandbox, hardened-runtime or library-validation protections to
silence a vendor warning.

Latency sums along serial paths; compensate differences between parallel paths
and remove global latency once. Fractional, changing or over-budget latency/
tail declarations refuse. Offline rendering uses an independent processor with
the same recipe and bounded input; current export ends at the exact program
boundary rather than appending an undeclared effect tail.

Export effects explicitly set `isRenderingOffline` before resource allocation
and request 4,096-frame blocks. The processor uses the smallest allocated effect
capacity, capped at 4,096 frames, while playback retains 512-frame blocks and
real-time effect mode. Latency and applicable tail declarations are still checked
before and after every native block; larger blocks amortize synchronous
out-of-process render and property calls without caching timing declarations.
Effects may select vendor-specific offline processing quality.

The offline renderer prepares at most one next source window while the current
window is mixed and written. Each input window is at most 240,000 frames, with
at most two retained input windows and one current mixed output. Source reads
remain serial with each other, and the effect graph remains serial and
sample-continuous. Structured child work is canceled and joined before failure
or cancellation returns, before source retentions can be released. Recheck
currency after prefetch and processing; full source validation across each
prepared window and the final render boundary remains required.

## Native state ownership

Each loaded episode chain has one controller. Docked/detached UI and multiple
windows must not instantiate competing processors or document histories.
Slot identity, unit identity and generation guard every late load, editor and
observation.

Native callbacks do bounded atomic notification only. A single serial queue
observes revisions every 200 ms with a one-second full-state fallback. Discard
stale observations. An unchanged captured baseline retains its exact bytes and
does not dirty the document.

Authoritative Save/Undo/Redo/close capture is fresh full-chain state, not the
last background observation. Hold the existing document barrier, suspend/drain
observers where necessary, and visibly abort on failure. Preserve AppKit
autosave's synchronous entry and independent save queue; details are in
[persistence](persistence-and-source-access.md#shared-document-undo-and-native-state).

## Live transport bounds

`WWMix/MixerRecipe.swift` defines production timing through `MixerLiveTiming`:

| Quantity | Current bound |
| --- | --- |
| Raw source window / prefetch | 48,000 frames / at most five windows |
| Startup raw readiness | Two source windows, shortened by finite remaining duration |
| Processing block | 512 frames |
| Scheduled processed target | 12,000 frames, 250 ms |
| Refill low water | 9,600 frames, 200 ms |
| Startup buffered / lead | 9,952 / 2,048 frames |
| Maximum prepared control horizon | 12,512 frames, about 260.67 ms |

Raw seconds ahead are not processed-control latency. Source preparation runs
separately from effects; each 512-frame block captures current controls on a
serial worker, not in the hardware callback. Bound occupancy using the native
sample clock, not callback timing alone. Final completion waits for
`.dataPlayedBack`, not merely scheduling. Do not claim a sub-100-ms production
control horizon.

Effect-latency priming can make progress before an output player exists;
transport-generation checks must still reject stopped producers. Source/map
surveillance continues while cached audio plays. Missing progress, source
changes and underruns stop visibly rather than inserting success-shaped silence.
`WWAUDIO_UNDERRUN v=2` emits aggregate counts/times only, not PCM, paths or
vendor state.

Append/refill registration shares one output-queue operation and clock
observation; a reservation may complete before its continuation is installed
and must finish exactly once on stop/cancel. UI progress reads an immutable
clock/cycle/failure snapshot under its own short mutex, never the output or
AVFAudio engine lock. Extrapolation is clamped to scheduled samples. The
one-shot watchdog targets low-water/end boundaries with a 50 ms maximum
snapshot interval and shorter terminal/startup retries; refill/starvation
decisions still use a fresh device observation.

Reuse full 512-frame planar output buffers only after their `.dataPlayedBack`
token completes. The queue-owned pool caps at 50 buffers (200 KiB of samples);
exhaustion refuses instead of growing or recycling active storage. Short
cycle/latency/tail packets retain exact independent allocations. Fresh completion
tokens and pool retirement prevent callbacks from releasing another session's
buffers.

Source listening prepares a bounded first window and shares a host clock across
tracks. Optional newly audible sources join only at a freshly verified future
boundary. Follow Playhead pages at the viewport edge; manual panning disables
follow without changing audio. Stop while playing/preparing preserves position;
Stop when already stopped returns to Episode Start.

Cycles reuse the running graph and compatible raw PCM; production retains its
effect history and compensation. Device time remains monotonic while program
position wraps. Live controls remain independent of PCM. Source validation
continues on cache hits, and explicitly bounded auditions do not inherit a
global cycle. Loop reuse is not proof of underrun-free behavior under load.

## Cache and waveform contracts

Ordinary witnessed audition PCM is process-local, limited to 16 MiB/64 entries
and keyed by raw witness, full format/channel, map/accepted revision, output
frames and recipe. Production raw preparation keeps its own eight-window cache.
Adaptive PCM uses binary `WWPCM1`, at most 16 five-second tiles/64 MiB with
independent recipe and current source/map checks. None is a grant, a complete
source copy or a persistent replacement recording.

Exact waveform reads are bounded to 30 seconds/2,048 bins; overview measurement
streams covered samples with at most 65,536 bins, 24 hours and 2,048 ranges.
Unmapped gaps are not measured silence and must not be bridged. A large visible
viewport is not permission for a whole-source PCM allocation.

Use immutable interval indexes, viewport-sized canvases and display-scale-aware
pixel extrema. Reproject off the main actor with cancellation and snapshot
checks; key geometry by actual media/timing inputs, not playhead updates.
Do not recompute word indexes, normalization or cut geometry on every transport
tick. Pointer/edit actions resolve the live projection at event time instead
of trusting a drawing snapshot.

Adaptive timing icons require a viewport-sized `ZStack`; positioned icons in
a bare `ForEach` stack vertically and displace the waveform. Native clip
accessibility buttons share the same immutable placements as drawing and live
in a pointer-transparent canvas. SwiftUI-backed native `visibleRect` can extend
outside bounds: local event monitors must test both bounds and visible rect.

Performance comparisons must identify generated workload, build, host and
measurement scope. CPU projection/layout benchmarks do not establish device
latency, acoustic quality, GPU frame rate or physical-hardware qualification.
