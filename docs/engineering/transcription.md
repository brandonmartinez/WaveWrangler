# Transcription

Transcription runs locally through `WWSpeech` and the pinned whisper.cpp 1.6.2
bridge in `WWWhisperNative`. No audio or transcript uploads, telemetry or
external inference process are part of this path. An outgoing-network
entitlement supports explicit model downloads, not media transfer.

## Models and execution settings

Settings offers Base English, Small English, Turbo (the default) and Large-v3.
Model filenames, exact byte counts, SHA-256 and pinned download revision live in
`WWSpeech/LocalWhisper.swift`. Download begins only on the user's explicit
action. Availability by size is preliminary; inference admits only exact
hash-verified local bytes. Cancellation/failed verification must not publish
an available model or reuse a partial download.

CPU, Metal and Automatic are explicit settings. Automatic resolves once per job
to available hardware; initialization failure stops that job rather than
silently switching backend. Explicit Metal on unsupported hardware refuses.
Thread choices are 1, 2, 4 and 8. The recognizer revision includes model hash,
resolved backend and threads; settings changes affect a new job, not an
in-flight recipe.

The app-wide `TranscriptionWorkerPool` admits 1-4 concurrent speaker lanes across
windows, default one. Each admitted worker has its own native context;
initialization serialization must not serialize inference. Queueing is FIFO
and cancellable, with permits released on every completion/failure/race.
Versioned configuration prevents an older async Settings update from restoring
an obsolete limit. Lowering a limit does not interrupt admitted lanes.

Resource admission is separate from the chosen lane count: memory is bounded
between 4 and 16 GiB using a quarter of physical memory, CPU demand by available
cores capped at 16, Metal by two active workers. Reservations account for
verified model bytes/native graph and multichannel rendering, not only mono
recognizer PCM. An impossible request fails explicitly; waiting is not progress.

## Input readiness and chunking

Every speaker requires an explicit confirmed Primary/channel, current accepted
timing and fresh gateway verification. Supplemental assets are not speech
Primaries. `PrimaryCleanupPlan` is metadata-only readiness, not a content grant.
No accepted-map gap becomes silence or an inferred clock.

IN/OUT are optional. Omitted ends use the union of each Primary's full aligned
extent, not just the intersection where all speakers overlap. Explicit stale
bounds require review; a requested lane still needs complete supported
coverage. Replacing timing or revoking a source cancels current work.

Render sequential, source-anchored bounded windows: at most 28 seconds of core
plus one second of context on each side, never more than 30 seconds of audio.
Pause-preferred chunking examines the last four core seconds at 10 ms RMS hops
for at least 300 ms below -50 dBFS and 20 dB below local p90. It chooses the
latest qualifying center or the fixed boundary. This is a chunking heuristic,
not VAD, silence detection, a cut decision or a timing vote.

Every aligned frame belongs to one core; overlap detections are owned by their
midpoint. Do not compact silence, concatenate unrelated coverage, render a whole
episode into memory or retime raw source coordinates to hide chunk seams.
`TranscriptionChunking.revision` identifies the boundary policy.

The native adapter accepts finite bounded mono PCM, resamples analysis to
16 kHz, and may scale an overshooting analysis buffer only. It never normalizes
source, listening or production audio. Digital zero can return known empty
input, but quiet nonzero audio is not presumed silence.

## Timing and provenance

Whisper returns segment intervals where valid. The local wrapper deliberately
does not supply token-level word boundaries or confidence probabilities;
word positions derived for editing are approximate, not exact acoustic edges,
accepted clock evidence or automatic permission to remove audio.
Untimed/invalid intervals remain explicit rather than receiving fabricated
precision. Repetitive output may be hallucination or real speech; its review
flag changes neither raw text nor timing and is not evidence of silence.

Persist raw recognition separately from review overlays, with model/recognizer
revision, captured source identity/channel, source-frame anchors and accepted
alignment provenance. Current review applicability rechecks that origin.
Persistent witness continuity across a remount does not relax live decoder
authorization; see [source access](persistence-and-source-access.md).

All speakers publish atomically only after final source/map/settings currency
checks. Failure/cancellation leaves prior transcripts, marks, cuts and working
range intact. Sequence progress updates so an older message cannot roll back
the displayed stage; keep unknown totals unknown.

A successful rerun retains confirmed/reviewed/manual positions and explicit
rejections against their exact immutable old origin and raw transcript history.
Do not rebind them to similar words in the new recognition. Undecided automatic
suggestions regenerate only after successful replacement; unchanged timing
retains existing cuts/range.

## Review and editing

Automatic filler suggestions never cut audio. Review/manual actions validate
captured word/source/timing and use named canonical Undo operations.
Common cuts affect all aligned dialogue; speaker mutes affect only the selected
speaker and preserve time. Timing replacement retires incompatible active
reviews/cuts/range rather than silently rebasing them.

The virtualized review table and detached view share one cleanup model,
selection/filter state, document and Undo history. Navigation/word indexes are
keyed by actual content and timing, not just transcript IDs; same-ID word
changes invalidate cached analysis. Playback position is view state and must
not trigger full review reclassification.

Keep detection display, approximate word timing, reviewed edit boundaries and
production composition distinct. Product interaction details belong in the
user guide; exact cut/clip coordinates are in [program timeline](program-timeline.md).

## Validation boundaries

Use synthetic fake recognizers for orchestration, stale-state, atomic publish,
chunk ownership and resource-race tests. Actual model-backed inference and
public-speech benchmarks require separate explicit opt-in and authorized local
inputs. Generated tiny-native probes establish bridge mechanics, not speech
accuracy or production qualification. Never commit model weights or interpret
historical model/media permission as permission for a new run.
