# WaveWrangler engineering guide

How the native macOS app is laid out and how to build and test it. The
[development workflow](../planning/milestone-runbook.md) and current refinement
session govern work; older milestone documents are historical references.

## Layout

```text
WaveWrangler.xcodeproj/           Hand-authored project (objectVersion 77, synchronized folders)
  xcshareddata/xcschemes/         WaveWrangler (build + unit tests), WaveWranglerUITests (XCUITests; GUI)
WaveWrangler/                     App target sources (folder is synchronized: new files are included automatically)
  App/                            Entry point and NSApplicationDelegate
  Document/                       NSDocument subclasses, store, persistence/lifecycle integration
  Library/                        Library window, shallow sidebar, collections/recent/unavailable entries
  Workspace/                      Episode workspace views
  Alignment/                      Native waveform lanes, exact-map projection, typed/manual correction and internal audition
  Sources/                        Source organization UI (groups/channels/epochs, primaries/backups, relink)
  Commands/                       Main menu and commands
  Settings/                       Settings window
  Support/                        Small shared helpers (e.g. declared type identifiers)
  Info.plist                      Document types and exported UTIs (merged with generated keys)
  WaveWrangler.entitlements       App Sandbox entitlements
WaveWranglerTests/                Unhosted unit tests (Swift Testing); never launch the app
WaveWranglerUITests/              XCUITests + accessibility audits (launch the app; GUI lock required)
Packages/WaveWranglerKit/         Local Swift package linked by the app
  Sources/WWCore/                 Domain model, logical IDs, schema versions, pure validated operations
  Sources/WWPersistence/          Formats/coder, publication protocol, recovery store, migration, autosave policy, library store
  Sources/WWPersistenceProbe/     `wwpersist-probe` headless CLI for multi-process/provider trials (synthetic files only)
  Sources/WWSources/              Source references: read-only gateway, access records, availability, import, relink
  Sources/WWDecode/               Read-only content gateway (the only source-content opener), native streaming decoder,
                                  format-interpretation descriptor, typed decode failures
  Sources/WWAlignEstimate/        Pure acoustic offset/drift PROPOSAL estimator with abstention (decoded Float buffers in,
                                  WWTimeMap proposals/unsupported maps out; no I/O, never approves a clock)
  Sources/WWAutoAlign/            Streaming whole-channel spectral fingerprints, precise speaker matching, robust affine proposal,
                                  and separate review-only source-local timing support;
                                  frozen WWAlignEstimate trees remain unchanged (see automatic-alignment.md)
  Sources/WWDerived/              Versioned map history/acceptance, M2-C5 derived-asset keys, app-cache asset store,
                                  cancellable job coordinator, consent-gated decoded-content digest (WW-020)
  Sources/WWAlignSegment/         Pure discontinuity segmenter (WW-017): splits a recorder group at offset steps/slope
                                  changes into per-epoch GroupTimeMaps; brackets stay unsupported; never approves a clock
  Sources/WWRender/               Pure group renderer (WW-018 candidate SRC): one GroupTimeMap transform for every
                                  same-group channel, exact plan + Kaiser-windowed sinc, bounded chunks; never opens files
  Sources/WWAlignPipeline/        Headless alignment pipeline (WW-021/WW-023): consent-gated bounded analysis, proposals and
                                  abstentions as derived results, accept/manual map revisions, aligned-asset render job,
                                  witnessed bounded waveform envelopes and map-backed internal listening windows
  Sources/WWOrganizer/            Library/workspace presentation: wording catalogs, preference keys,
                                  collection/combine operations, library session, sidebar models, menu shortcut register
  Tests/WW*Tests/                 Swift Testing suites per module
scripts/build.sh, scripts/test.sh Established build/test commands (CI runs the same scripts)
scripts/demo/                     Manual demonstration helpers: synthetic fixture generator, metadata-only fs manifest
                                  (see docs/m1/evidence/m1-demonstration.md; outputs go to $TMPDIR, never a repo)
.github/workflows/ci.yml          Ordinary build/test CI
```

`WWTimeMap` contains the exact source/group/aligned coordinate maps.
`WWCommonEdit` contains the provisional common episode edit-map implementation;
its presence does not mean export or protected-cut acceptance is complete.

### Manual cuts and editing layouts

The current marker/selection toolbar provides **Cut across all aligned tracks**.
This is an explicit manual operation, not automatic filler removal or protected-cut
approval. It records an original-aligned, half-open interval on the shared 48 kHz
listening grid in `EpisodeCleanup.manualCuts`; recordings, accepted alignment,
marker provenance, and raw transcripts remain immutable. Every aligned track
uses the same merged removal intervals, including hidden, muted, and backup
tracks. Later audio ripples to the interval's start. Playback requests split into
kept aligned windows before gateway reads; waveform and transcript presentation
use the same shortened timeline. No export behavior is introduced.

Applied markers become single red scissor rails. Selecting a rail shows the same
compact, inline toolbar used for other markers above the clicked track, not the
first track. Clicking an expanded interval or its handles also keeps that track
as the editing context; the cut itself still applies across all aligned tracks.
The toolbar is a window-level overlay anchored to the waveform, not a row in the
track layout: showing or hiding it never resizes tracks or changes header wrapping.
Clicking elsewhere in the window dismisses the tools without consuming the click,
changing marker boundaries, or collapsing an expanded cut. Selecting the same
marker, cut, or boundary reopens its tools.
**Show cut** expands only that
cut into the waveform/transcript timeline; every other cut stays applied, including
during playback. Drag either boundary independently, or focus a handle and use
Left/Right or accessibility adjustment for 1 ms changes. Each completed drag or nudge
is one undoable edit across all tracks. **Hide cut** returns to the red seam.
Showing/hiding is device-local view state, never a document edit or an Undo entry.
**Zoom to cut** focuses the collapsed join, or the full editable interval when
shown, with surrounding context and the existing zoom limits. Zooming does not
toggle Show/Hide, seek, change the selected cut, or create an Undo entry. It also
works on aligned tracks before transcription Primaries have been confirmed.
Hear the removed interval, add context, or collapse it to compare the edited join
using current Solo/Mute choices. **Restore interval markers**, the
context menu, or Undo/Redo recovers audio. Linked markers retain their original
provenance and restore with the adjusted boundaries. Fade/blend is deferred; no
crossfade or smoothing is silently applied. Cuts retain their
alignment revision and become inactive, with a warning, if accepted timing
changes; they are never silently rebased. Schema 8 adds the optional cut records.
Schema 1–7 shows require the existing consented migration and exact-byte backup;
migration introduces no cuts.

**Speakers only** shows confirmed Primary sources grouped by speaker and
automatically mutes all non-primary sources when selected. Primary Solo/Mute
choices and assignments stay unchanged. These session mutes remain when switching
layouts; **Restore listening choices** recovers the previous listening state.
The other comparison layouts remain available for alignment. Transport, editing
tools, layout, zoom, and the time ruler are anchored to the top of the workspace
as window-style chrome; only the tracks scroll. The outer waveform box is removed
so lanes fill the available space. Selection controls float above their active
lane, and the zoom icons step by a factor of 1.25 around the playhead using the
existing zoom limits.

Each episode's last workspace view is stored in device-local preferences keyed by
show and episode ID, not in the canonical document or its Undo history. Reopening
restores layout, normalization, lane height, zoom, edited viewport/playhead,
vertical track scroll position, collapsed groups, destination, and sidebar choices.
It also stores the bottom review panel's visibility/divider height, Fill Space and Follow Playhead.
Older view records preserve the transcript-panel choice and decode Fill Space/Follow Playhead as
off/on respectively, without changing canonical schemas. Fitted height is derived
from the live viewport and measured content, never written over the bounded manual
height. Fit mode measures all rows, including group chrome, transcript strips, errors,
and metadata-only Ungrouped rows; ordinary manual mode retains lazy track stacks.
Measurements carry the lane height they were produced from so stale geometry cannot
drive a resize feedback loop. Minimum-height overflow remains scrollable.

The selected-view menu retains all four serialized modes in By recorder, By speaker,
Overlay, Speakers only order. Align Tracks and Transcribe Tracks sit beside it on the
left; normalization, sizing/fitting, interaction tools, and the single refresh action
form the trailing group. Refresh retains waveform cancellation and cleanup readiness
refresh. Workflow guards and explicit alignment review/acceptance remain unchanged.
Playback never resumes automatically. Solo/Mute choices are not restored; reopening
**Speakers only** applies its non-primary mute policy again.
The selected expanded-cut view is also remembered, provided that cut remains
active at the accepted alignment. Navigation preference writes are coalesced;
closing a document or quitting flushes the latest view immediately.
Cold reopening a zoomed-out view first loads a bounded exact audio tile, then
builds the full overview without changing the saved viewport. The 30-second
exact-read limit does not limit the visible timeline span or leave track rows
and playback uninitialized.

### Review queue and keyboard focus

The Transcript & Review queue lives in a resizable bottom `VSplitView` pane, not in the trailing
inspector's scroll stack. A native-backed `Table` virtualizes visible rows; columns separate speaker,
phrase, status, aligned timestamp, duration and row actions. Header filters wrap at narrow widths.
The trailing inspector shows just the selected review or cut, timing fields, decisions and collapsed
captured-origin/transcript details. Display timestamps use milliseconds; the underlying source-frame
anchors and exact captured timing remain unchanged.
Cleanup artifact identities retain the explicitly confirmed recorded witness when the freshly
admitted file matches all persistent identity fields. Mount-local device numbers and filesystem IDs
may change after remounting; those alone must not invalidate saved transcripts or reviews. Live
authorization, decoding and per-read revalidation still use the complete current kernel witness.
No saved origin, accepted alignment revision or source grant is rewritten to recover this continuity.
The native divider position is restored after layout and persisted from resize notifications;
an `idealHeight` hint alone does not restore `VSplitView`'s actual position.
The split contains only the scrollable tracks and bottom Review/Mixer pane. Transport, view controls
and ruler remain above it in the fixed waveform chrome, so opening a pane or restoring a tall
divider position cannot clip the controls. At short window heights the bottom pane yields space
before the 64-point track viewport or fixed controls; undersized temporary pane heights are not
written over a valid saved divider preference. Pan/zoom event capture stays confined to the tracks.

`reviewRows` caches source/timing issue classification by model generation and is invalidated when
the verified plan or source identities change. Panning/playhead updates do not revalidate hundreds of
reviews. Waveform filler markers reuse the same classification snapshot rather than rechecking every
adaptive region for every playhead update; source/plan evidence still invalidates it.
Table selection defers navigation to the next main-actor turn to avoid reentering native
table delegates; a newer row request supersedes an older one. Row navigation centers/zooms the
interval, expands any collapsed parent groups and scrolls its source into view. Auto Cut and Restore
call existing manual-cut operations, with no
new detector or edit-map format. Symmetric 10 ms resize controls reuse existing marker/cut validation
and Undo, including linked-marker synchronization for accepted cuts.
The table's primary action and readable cells audition the current row without context through the
existing filler transport, or reveal/audition removed audio for a cut row. Embedded controls handle
native double-click counts because they consume the table's primary action. Activation cancels
pending selection navigation so it cannot stop the new audition.

Transport keyboard routing runs only for an episode workspace without an attached sheet. It yields
to native controls, text editors, the review pane, inspector controls and the focused accessibility
role, preserving SwiftUI boundary-handle arrow events. Space ignores repeat events; Left/Right and
the transport buttons share the typed `TimelineJumpInterval` preference. This setting changes only
navigation, not episode documents or active inference configuration.

Waveform projection/reprojection runs off the main actor with cancellation and
snapshot checks before publication. Waveform pixel aggregation and path drawing
use an asynchronous Canvas. Transcript preparation projects and indexes words once
per input/cut snapshot; pan/zoom queries use binary viewport lookup, preserving
overlapping words and stable ordering. Each prepared word index retains one
viewport layout keyed by start, duration, width, and uncertain-word IDs. Playhead
and selection changes reuse geometry; changing words, cuts, or source bounds
replaces the index and its layout cache. Accepted adaptive markers live in a
value-only equatable subtree keyed by segments and viewport geometry, so moving
the playhead does not rebuild hundreds of timing icons and accessibility/help labels.
That subtree is a viewport-sized `ZStack`; positioned icons must not stack
vertically or enlarge the surrounding waveform layout during resizing or zooming.
Marker neighbor distances use one sorted
pass rather than pairwise scans. Listening reuses the existing bounded, witnessed
PCM cache, including adjacent/overlapping cached windows for indexed seeks.
Cache hits still require current source identity, format/channel, and map-revision
verification; no full-file audio copies or source-authorization shortcuts are added.

Waveform canvases are viewport-sized, including at close zoom; cached tiles are
clipped in viewport coordinates rather than rendered into oversized surfaces and
then translated. Immutable interval indexes select overlapping measured bins,
including bins whose midpoints are offscreen, before pixel aggregation. Separate
group-clock indexes preserve independent epoch drafts and hit-test ordering.
Pixel extrema use dense, display-scale-aware storage with separate mapped and
unmapped columns. Normalization, retained coverage, and proposal geometry are
prepared on snapshot changes, not recomputed by each row's view evaluation.
Recorder and speaker rows use lazy stacks; offscreen rows materialize on scroll,
while the transport, ruler, and track controls remain anchored.
Navigation bounds combine extents cached on each immutable waveform index rather
than rescanning overview bins. Pointer-selection drags do not materialize the
separate recorder-move hit-test strokes. Timeline chrome uses a cached responsive
layout with one control hierarchy: nested `ViewThatFits` alternatives previously
repeated native-control intrinsic sizing throughout every pan update. Row/column
choices use measured content, not fixed window-width breakpoints, and invalidate
their proposal caches when content or typography changes.

The synthetic viewport benchmark on VM `ww-ui-2` (macOS 27, four vCPUs,
Debug build, 960-point viewport at 2x scale) recorded:

| Workload, 60 frames | Full scan / scaled tile | Indexed viewport |
| --- | --- | --- |
| 120,000 stored bins, 0.5-second pans | 0.628 seconds | 0.043 seconds |
| 2,048-bin, 30-second tile at 0.5-second zoom | 2.305 seconds | 0.035 seconds |

The close-zoom surface is 960 points wide instead of 57,600; the large-timeline
query selects 51 bins rather than visiting all 120,000. A hosted 32-track
recorder-layout check initially materialized three rows and showed five after
scrolling to the end, including previously offscreen sources. These are CPU
microbenchmarks and row-lifecycle checks, not end-to-end frame-rate, GPU, or
physical-hardware qualification. The implementation keeps asynchronous SwiftUI
Canvas and Apple's graphics stack; a custom Metal renderer is not justified by
these demonstrated CPU-side bottlenecks.

A subsequent full hosted pan-update comparison on the same VM used six synthetic
tracks, 12,234 overview bins, a 1,200 x 800 window, and 60 updates:

| Work per update | Before, p50 / p95 | Cached navigation and chrome, p50 / p95 |
| --- | --- | --- |
| Navigation bounds / fit | 5.703 / 6.357 ms | 0.041 / 0.086 ms |
| Yield plus hosted layout / display | 175.158 / 266.268 ms | 16.157 / 19.661 ms |

Removing navigation scans alone left hosted updates near 178 ms at the median.
An eight-second main-thread sample then identified repeated SwiftUI adaptive
layout and native-control sizing, not waveform decoding or a GPU wait, as the
remaining dominant cost. The second row includes a 1 ms suspension, run-loop
scheduling, and forced hosted layout/display; it is not an FPS measurement or a
Logic Pro parity claim. The same final run measured zoom updates at 17.525 /
22.090 ms and recorder placement previews at 8.244 / 11.184 ms (p50 / p95),
without committing timing edits.

Because app folders are `PBXFileSystemSynchronizedRootGroup`s, adding/removing files under
`WaveWrangler/`, `WaveWranglerTests/` or `WaveWranglerUITests/` does **not** edit `project.pbxproj`.
Only touch the project file for genuine target/build-setting changes and avoid
overlapping edits. Non-source files placed in `WaveWrangler/` are copied as
resources unless listed in the target's membership exceptions (as `Info.plist` is).

## Module boundaries

The owner names in the historical table below describe the original implementation,
not active Squad roles or approval gates. Work directly across the relevant
boundaries as needed, keeping independently edited surfaces disjoint.

| Area | Owner | Notes |
| --- | --- | --- |
| `App/`, project/targets, `Support/`, `WWCore` domain model, this guide | Mac (app foundation) | Schema changes require a schema bump + migration plan. |
| `Document/`, `WWPersistence` | Persistence owner | Publication, prior checkpoint, recovery, migration, autosave policy, newer-format refusal. |
| `Library/`, `Workspace/`, `Commands/`, `Settings/` | Library UI owner | Keyboard/VoiceOver/visible focus are part of done, not polish. |
| `Sources/`, `WWSources` | Sources owner | Access records, bookmarks, availability/download states, relink. |
| `WWDecode` | Mac (WW-050) | Only `SystemSourceContentIO.swift` may open source content, read-only (`ForbiddenAPITests` enforces this, recursively). No writes, no dataless materialization, no partial publication on failure or cancel. Bump `formatInterpretationVersion` whenever the interpretation of the same bytes changes. Envelope evidence: [`docs/m2/evidence/ww-050-decode-envelope.md`](../m2/evidence/ww-050-decode-envelope.md). |
| `WWAlignEstimate` | Alignment (WW-016/WW-021) | Pure: imports only Foundation, WWCore and WWTimeMap; no file/content/decode APIs, no Accelerate, and no clock-approval surface (`EstimatorPurityTests`). Emits only `acousticConsistentProposal` or a typed abstention; audio alone cannot tell propagation delay from clock change, so it never produces `clockApproved`. Scores are not probabilities, and the vocabulary scan bans such wording. Calibration and the frozen holdout definition: [`docs/m2/evidence/ww-016-estimator-calibration.md`](../m2/evidence/ww-016-estimator-calibration.md), [`docs/m2/fixtures/m2-freeze-estimator.json`](../m2/fixtures/m2-freeze-estimator.json). |
| `WWAutoAlign` | Alignment | Native, decoded-buffer-only acoustic candidate for selected-speaker Align: time-indexed whole-channel fingerprints, content-selected NCC/PHAT evidence and bounded robust affine fitting. The pipeline caches fingerprints through the authorized gateway and revision-checked derived coordinator. No source I/O or clock-approval surface in the estimator. It is versioned separately rather than changing frozen v1 semantics. Design, exact bounds and synthetic evidence: [automatic alignment](automatic-alignment.md). |
| `WWDerived` | Mac (WW-020) | Versioned maps are append-only revisions with one accepted pointer, embedded in the show (`Episode.alignment`, strict canonical `WWTimeMap` JSON, re-validated on open and save). Derived assets live only in the app cache: `DerivedAssetStore` refuses roots in or containing a source folder (canonical, case-folded paths; only exactly the user `~/Library` is exempt) and roots in iCloud Drive, `~/Library/CloudStorage` or any ubiquitous location. Assets are keyed by every M2-C5 component, and publish only after a currency check in the same coordinator turn (late results are discarded). The owner calls `DerivedJobCoordinator.shutdown()` before releasing source access: it cancels every job, refuses later submits and returns once no job runs; releasing the coordinator also cancels its jobs. Content digests need an explicit per-source request and availability ON, and go through `SourceDecoder` only. `ForbiddenAPITests` confines file mutation to `DerivedAssetStore.swift` and hashing to `DerivedAssetKey.swift`/`ContentDigest.swift`. |
| `WWAlignSegment` | Alignment (WW-017) | Pure: imports only Foundation, `WWCore`, `WWTimeMap` and `WWAlignEstimate` (public API only; the estimator stays frozen under `m2-freeze-estimator`). `SegmentPurityTests` and the repo-wide scan ban file/content/decode APIs, random/UUID/shuffle/hashing APIs (epoch IDs are minted at exactly two counted sites), wall clocks, concurrency, `clockApproved` and probability wording. Every region is its own epoch: mapped regions are `acousticConsistentProposal`, and anything not localised to the WW-016 gate stays a typed unsupported region (no inverse). It never fits one map across a detected jump. Revision 2 requires time-persistent fitted runs before declaring a boundary; the rev-1 failed holdout remains recorded. Calibration harness concurrency is capped by `WW_SEGMENT_MAX_CONCURRENCY` (default 4, may only lower). CI runs only the gated calibration (`WW_SEGMENT_SWEEPS=0`); the floor and edge-silence sweeps run in local `scripts/test.sh`. Evidence and frozen revision: [`docs/m2/evidence/ww-017-discontinuities.md`](../m2/evidence/ww-017-discontinuities.md), [`docs/m2/fixtures/m2-freeze-discontinuity-2.json`](../m2/fixtures/m2-freeze-discontinuity-2.json). |
| `WWRender` | Alignment (WW-018) | Pure: imports only Foundation, `WWCore` and `WWTimeMap` (`RenderPurityTests` plus the repo-wide `ForbiddenAPITests` scan). Consumes plain decoded buffers through `RenderSampleProvider`; applies no gain, mix, proxy or stretch. It plans from `GroupTimeMap` inverses and never redefines their conventions. Bump `RenderVersions.renderer` (or `RenderRecipe.currentVersion` / `RenderVersions.outputAssetFormat`) whenever the same inputs would render or lay out differently. The SRC is a calibrated **candidate**, not qualified. Listening is blocked. Calibration and the frozen holdout definition: [`docs/m2/evidence/ww-018-render-calibration.md`](../m2/evidence/ww-018-render-calibration.md), [`docs/m2/fixtures/m2-freeze-render.json`](../m2/fixtures/m2-freeze-render.json). |
| `WWAlignPipeline` | Alignment (WW-021/WW-023) | Headless; no UI. Reads content only through `SourceDecoder` (consent-gated, availability ON, registered sources only; metadata-only/OFF paths do zero decode work) and writes only through `DerivedJobCoordinator`, so every result is keyed by every M2-C5 component and publishes only after the coordinator's currency check. The estimator's output stays `acousticConsistentProposal`; accepting it records `manual` with basis `acceptedAcousticProposal`, and no path here can construct or carry forward `clockApproved` (`ForbiddenAPITests` scans the module with no exceptions; an approved prior map is refused). Concurrency is `PipelineConfiguration.concurrency` (1…4, default 2; never sized from the processor count) and one shared `ResourceGate` admits analysis and render units against a byte budget (default 512 MiB). Analysis decodes one decimated mono stream per side (≥8 kHz, bounded excerpt); bump `AnalysisDecimator.designVersion` or the recipe names in `PipelineConfiguration` whenever results would change. Aligned assets render every group at one episode-wide rate from the WW-050 `OutputSettingsPolicy` (`PipelineConfiguration.outputSettings`; the policy version is in the render recipe name) and stay binary32 in the cache. The pull-based `SourceDecoder.withDecodingCursor` feeds both analysis and `WWRender`. Accepted proposals keep only their measured interval (frames outside stay `outsideCoverage`; extending to the epoch is an explicit `manual` decision). Acceptance is serialized per episode and refuses stale snapshots and stale plans; each map revision persists a dependency digest (placements, revision tokens, format) that `activate` and every render re-verify, and every aligned segment's key names the accepted map's content identity, so distinct maps never share audio. `AlignmentPipeline.shutdown()` returns only after every render's cursors are closed. Export stays blocked (M4). Evidence: [`docs/m2/evidence/ww-021-alignment-pipeline.md`](../m2/evidence/ww-021-alignment-pipeline.md). |
| Planned (M2) | — | `WWTimeMap` (WW-015) adds its row through its own lane. See [`docs/m2/ww-019-m2-contracts.md`](../m2/ww-019-m2-contracts.md). Each lane adds its own row here when its module merges. |
| `.github/workflows/ci.yml`, `scripts/` | Mac (app foundation) | Keep scripts working for every lane. |

Pure domain logic belongs in the package (testable without the app); the app target holds AppKit/SwiftUI
integration. `WWPersistence` and `WWSources` depend on `WWCore`; `WWDecode` depends on `WWCore` and
`WWSources` (scoped access); `WWPersistence` also depends on `WWTimeMap` (embedded map validation);
`WWAlignEstimate` and `WWRender` depend on `WWCore` and `WWTimeMap`;
`WWAlignSegment` depends on `WWCore`, `WWTimeMap` and `WWAlignEstimate`;
`WWDerived` depends on `WWCore`, `WWTimeMap`, `WWSources`, `WWDecode` and `WWPersistence`;
`WWAlignPipeline` depends on those plus `WWAlignEstimate` and `WWRender`; nothing depends on the app.
The selected-speaker path additionally depends on `WWAutoAlign`; general multi-recorder cycle analysis
continues to use the frozen `WWAlignEstimate`.

### Listening startup and replay

Aligned transport prepares one second of the initially audible tracks, then fills
contiguous half-second output-frame windows with at most 3.5 seconds queued ahead.
All tracks use the same exact output ranges and shared host clock. Muted tracks do
not render before audible startup. One optional source at a time warms up to one
second in the background, targeting a later producer window rather than racing the
immediately next request; only an enabled source with a freshly reverified window
can join a future transport boundary. Pending or unavailable sources are reported
without restarting the other tracks. A missed producer deadline stops playback
with an explicit error instead of treating an underrun as successful listening.

Follow Playhead pages only the viewport at its right edge, or reacquires a playhead
behind its left edge, for unrestricted, cycle, selection, and marker playback.
There is no early 80-percent recenter. Manual panning disables follow until explicitly
enabled again; enabling immediately reacquires without changing the audio clock.
Transport and review controls remain pinned outside the track scroll area.

Source resolution and accepted-map activation are batched once per window, not
once per track. The runtime's ordinary audition cache is process-local, limited to
16 MiB of PCM and 64 entries, and keyed by exact raw witness, complete decoded
format, group map, accepted episode/revision, channel, output frames and render
recipe/version. Contained windows can reuse the same samples. Every hit still opens
the witnessed decoder, validates the measured format/channel against the placement,
and checks source identity; the runtime also rechecks device access and the accepted
map before returning audio. No cached PCM grants authorization or substitutes for a
changed recording. Adaptive corrections retain their independently verified
five-second tile path; a cold adaptive tile can still dominate preparation.

The immutable default sinc prototype is shared between renders and never built for
identity-only plans; samples, render recipes and historical DSP qualification are
unchanged. Stop clears scheduled audio but retains the compatible paused transport
graph, reducing repeated engine/node setup. Each restart still has the existing
100 ms scheduling lead: these changes do **not** promise gapless cycles or measured
physical audio latency.

The opt-in synthetic listening benchmark exercises generated 48 kHz PCM, identity
and +100 ppm maps, two audible tracks, multiple windows and three cycles. Its useful
local acceptance is cold first-window preparation below 1.5 seconds, faster than
preparing the former five-second window, subsequent windows before the synthetic
scheduled deadline, exact repeated samples, and bounded cache storage. It measures
witnessed PCM production, not full app admission, device start or acoustic latency.
On 2026-10-20, same-host generated-PCM measurements were:

| Build / two-track maps | Former 5 s window policy | Cold 1 s first window | Cached first window (cycles 2-3) | Cold 500 ms fill |
| --- | ---: | ---: | ---: | ---: |
| Debug / identity + drift | 2,457 ms | 487 ms | 0.57-1.34 ms | 242-247 ms |
| Debug / two drift | 4,733 ms | 948 ms | 0.77-1.03 ms | 472-483 ms |
| Release / identity + drift | 108 ms | 22.5 ms | 0.51-0.87 ms | 12.0-12.8 ms |
| Release / two drift | 247 ms | 43.6 ms | 0.61-0.90 ms | 22.8-25.9 ms |

These are observations, not a p95 guarantee; each case has one cold cycle and two
cached cycles. The five-second comparison uses the former window policy on the
current renderer. Separately, the pre-change Debug renderer-only baseline measured
88.8-89.8 ms for five-second identity, 18.1 ms for 500 ms identity and 249-253 ms for
500 ms drift; after kernel reuse those measured 77.4-78.6, 7.80-7.89 and 237-241 ms.
Each two-track case retained 1,536,000 PCM bytes, with 14 misses and 28 witnessed
hits across three four-second cycles. Serial macOS VM hosted regressions also
exercise three real model playback cycles, synchronous Stop, live unmute/Solo
without restarting the shared clock, and the actual producer-deadline callback
with synthetic recordings. Those are functional checks, not measurements of full
app admission, physical output startup, or gapless cycles. More simultaneous
drifting tracks and cold adaptive tiles are not covered by this two-track timing
acceptance.

Run with the normal package scratch directory and bounded workers:

```sh
WW_LISTENING_BENCHMARK=1 SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=2 \
swift test --package-path Packages/WaveWranglerKit --scratch-path .build/swiftpm \
  --jobs 2 --no-parallel --filter 'AlignedAuditionStartupTests|ListeningRenderStartupTests'
```

### Bounded visual alignment

The native episode editor opens into the integrated all-source workspace. It shares one transport,
ruler and listening state with progressive transcript annotations and contextual review. The fixed
action strip exposes recording management, refresh, transcription and its model/Preferences shortcut.
Legacy Setup, Alignment and Edit & Cleanup remain in Views and their keyboard commands; Export
opens the existing unavailable explanation, not an export engine. Its contextual
Recording inspector owns speaker/channel assignments, group nudges, numeric timing, and picked-point
anchor actions; timing evidence is expandable. Grouped top-bar buttons toggle one Recording,
Alignment, Transcript & review, or Episode sidebar at a time. The Alignment sidebar owns the
epoch/anchor tables, detailed timing actions, and status previously shown below the tracks;
its tables scroll horizontally in narrow windows. Recording settings buttons select their own source
and open that inspector. The compact plus opens the existing native recording/speaker management
surface in a sheet rather than switching stages or duplicating source records. Import
identity is provisional until the user explicitly confirms an unchanged original; the Setup engine
checks current metadata and captures the decoder-owned raw witness before saving confirmation.
Relink/Grant Access can also restore a missing device-local record or accept different file details
only after the user acknowledges the comparison; the chosen local file is rechecked around read-only
raw-witness capture before its new confirmed baseline is saved. It never silently substitutes a file.

The compact primary and Command-click tool menus contain only Pointer, Move recorder, Reviewed,
and Reject. Command temporarily selects the second tool; release or window deactivation restores
the primary. Review tools target existing filler regions through the same undoable model actions;
they never cut or erase audio. Move recorder retains position locks and reference protection.
Unplaced groups and directly entered manual timing remain movable unless explicitly locked;
accepted automatic proposals retain their default protection. Confirmed dynamic timing blocks
manual movement, anchors and numeric edits only for its own recorder and timing reference.
**Reset dynamic timing** removes that file correction through the existing verified-save and
Undo/Redo path; unrelated recorders remain editable, and their changes preserve the correction
and its unchanged reference map.

**Anchor points** above the tracks also exposes the Recording inspector's picked-point actions.
Click a sound on a timed track or the fixed reference and choose **Mark reference point**;
click the matching sound on another recorder and choose **Link matching point**.
One pair applies offset at the current rate; another pair can fit offset and drift.
Saved pairs use the existing source-specific anchor note, and subsequent recorder drags
translate their aligned times without changing rate or originals. Pairing is an explicit manual
decision, not acoustic or clock proof, and does not require matching speaker assignments.
Reference points are discarded when the document generation changes.
The single marker toolbar is centered on the visible selected interval and clamped to its track.
It retains audition/context/loop access and adds Reviewed, Reject, Clear review, and Revert to
detected. Clear review resets only the decision; it keeps adjusted bounds, detection, audio, and text.
Numeric marker fields and the duplicate marker popover are removed; graphical handles and their
keyboard/VoiceOver adjustments remain.

Above the tracks, Listen now presets sit beside Add. Their active state reflects current listening
choices, and Restore listening choices returns to the pre-preset choices. These session-only
presets preserve explicit Mutes and do not change roles or the app default.
**Preferences > General > After alignment** controls listening after newly accepted
alignment is verified on disk. The initial default mutes non-primary tracks; Keep
my playback choices, Solo primary tracks, and Solo non-primary tracks remain available.
The policy runs once for that acceptance, never on refresh, reopening, preference
changes, or Undo/Redo. Restore captures the mix immediately before the policy.
Legacy serialized episode policy keys remain readable and are not rewritten.

**Align Tracks** analyzes every eligible recorder epoch using explicitly identified
shared speaker channels. A single review lists proposals, abstentions and missing
prerequisites, with Recordings & Speakers and advanced/manual timing remedies.
Each proposal names its reference recording and captured accepted timing revision;
already aligned reference groups are historical evidence, not silently rebased to
other proposals in the batch.
Only checked measured proposals are accepted; unsupported/unselected epochs and
unmeasured intervals remain unresolved. No proposal is automatically extended.
Realignment warns before analysis and authorizes moving locked non-reference groups
only for replacement acceptance. Existing timing and downstream work stay live during
analysis/review. Accepting replacement alignment resets active transcription,
revision-bound reviews/cuts, and episode IN/OUT in one undoable transaction; originals,
assignments, raw transcript history and append-only timing history remain. Failed or
canceled analysis/review does not reset work. Activation requires verified save.

**Transcribe Tracks** requires verified accepted Primary timing, source identity,
coverage and an available local model. Repeated transcription warns before running.
Successful publication retains reviewed/adjusted/manual marks (including pending
manual marks) at their exact captured positions and retains explicit rejections.
Their immutable old transcript provenance is verified against retained raw history,
never rebound to new words. Source/channel/identity/alignment and coverage guards
still apply. Same-source overlapping source-frame events suppress duplicate suggestions
independently of new word IDs. Undecided automatic suggestions regenerate only after
successful transcription; failure/cancellation leaves them intact. Unchanged alignment
preserves cuts and episode IN/OUT. Publication and Undo/Redo cover all speaker results
and suggestions together.

The decoding-boundary scan distinguishes in-memory nominal conversion from source decoding:
only `WWDecode/PCMResampling.swift` and `WWSpeech/LocalWhisper.swift` may name
`AVAudioConverter` for already-decoded PCM. Raw `AudioConverter` and file/asset readers
remain forbidden in both helpers; private content-gateway APIs remain restricted to `WWDecode`.
Debug cleanup public-speech fixtures also inspect their explicitly supplied local WAV through
`SourceDecoder.withDecodingCursor`, never an app-owned audio-file reader. The header-only probe
requires mono 48 kHz PCM WAVE and 4-30 seconds, verifies the source unchanged, and reports errors
without creating a show; it does not read samples or authorize any other media.

Layout is per-window presentation: separate lanes can be grouped by recorder or assigned speaker,
while overlay groups recordings by speaker, including muted tracks. Both speaker layouts use the same
source-to-speaker projection and retain unknown speakers. Recorder IDs and group-move semantics
are unchanged; switching layouts preserves independent Solo/Mute, selection, cycle and the shared viewport.
`AlignmentPipeline.prepareManual` gathers header facts without requiring estimator output; initial
placement maps only one eligible epoch per non-reference group so recorder restarts with overlapping
source clocks are not invented as synchronized. The user can place later epochs individually.
`shiftAcceptedGroup` translates every supported segment of a non-reference group in one revision,
preserving gaps, unsupported epochs, source spans, Undo, and canonical save verification. Playback
prepares separate timed source windows on a shared clock; enabled untimed sources remain visible but are
explicitly excluded, and playback refuses if none is timed and audible at preparation.
Independent S/M controls apply to files, speakers and recorder groups: matching Mute always wins,
and multiple Solo scopes add their member files together. Group controls never erase member choices
or change Primary/Backup roles. Live gain changes do not pause or reset playback; muting every track
while running advances silently. An unavailable muted source cannot be heard if unmuted until playback is restarted, and
the transport reports why. Each source window still requires the verified map, source witness, and
exact decoded format to match; a mismatch on an enabled source stops playback rather than
substituting audio. It may buffer between windows; it does not create an export or promise seamless
transport. "Timing not set — not attempted" describes the epoch's clock state,
not the recording's file format; manual numeric timing or anchors do not require an estimator run.

`WaveformWindowReader` produces at most 2,048 extrema bins per recording for a viewport of at most
30 aligned seconds. Its existing witnessed full-source overview targets 20 ms extrema bins,
retains at least the former resolution for short sources, and caps each source at 65,536 bins.
Overview cache recipe 3 invalidates the older 2,048-bin whole-source results. The existing pipeline
resource gate admits 16 MiB plus the configured bounded decode chunks for the overview's transient
extrema/encoding work; decoding remains
streamed and range/channel/witness checked. The cap can coarsen detail for very long sources;
only pauses resolvable in the measured bins and viewport can be shown. Untimed recordings begin as dashed source-origin previews at aligned zero,
including when another group has accepted timing. Soloing one untimed recording makes Play
an explicitly labeled **original source-time** audition: no alignment is assumed or saved,
episode cuts are not applied, and no other recordings are mixed. It uses the same witnessed
renderer and bounded playback worker with an ephemeral identity map that is never persisted,
activated or supplied to production mixing. Normal multi-track listening still requires accepted,
verified timing. `WaveformViewport` inverts each supported affine segment into the correct source
frame windows, clips to occurrence spans, and never reads gap frames into an envelope. Unsupported
spans are visibly unplaced source-origin previews. Opposite-polarity channels retain their peaks;
the envelope is not mono PCM, an alignment estimate or edit authority.
The alignment workspace puts a compact transport with a centered editable live playhead and five-second
skips above compact icon/slider zoom and lane-height controls beside Fit Timeline.
Zoom and lane-height use the shared `NativeTimelineSlider`: real AppKit sliders retain
numeric thumb values, keyboard adjustment, inherited disabled state and continuous
bindings. Zoom refreshes measured detail when editing ends, not on every drag sample.
The adaptive ruler
uses a larger draggable flag and a high-contrast position line through each waveform, and offers evenly
spaced time ticks: click to seek, drag its visible marker to move the
playhead, drag empty ruler space to pan without moving the playhead, or pinch to zoom centered on the
playhead. Horizontal scrolling over the waveform workspace pans time; Option-horizontal
scrolling zooms around the playhead and Option-vertical scrolling resizes the lanes. Ordinary vertical
scrolling is passed through unchanged to the workspace scroll view. Seeking and panning change
presentation state and do not require unrelated document edits to be saved; accepted playback
and timing edits retain their verification checks.
Aligned time may be negative relative to the reference, and verified
negative placements can be sought and played. The marker and all lanes share the same time-to-pixel transform; the ruler
also exposes its range and a Stepper representation of the visible playhead to accessibility clients.
Its nudges use the existing bounded seek and playback-resume path. Alignment inspectors keep timing
actions and audition settings in labeled single-column groups with independently accessible controls.
The empty alignment workspace reuses the Library's `CenteredScrollView`, scaled text styles,
and a native text foreground so the recovery instructions and Add recordings action can scroll
when space is constrained.
Recorder-group headers sit
beside adjustable-height
source lanes; a translucent overlay with source selection is available for peak matching. Separate
lanes and overlay share a ruler and playhead, selected with one segmented control. Overlay panels
group the recordings by speaker (with an Unknown speaker panel for unassigned sources),
while selection, drag, save and Undo/Redo still operate on the entire recorder group across panels.
Zoom changes the
visible transform around the playhead with the slider, Option-scroll, or pinch, including after
panning away. Zoom never seeks; it clamps at the available viewing bounds.
The compact word-review toolbar omits duplicated selected-word/status text and offers
**Zoom to word**, which instead fits the complete selected interval with surrounding context
without moving the playhead or changing the review decision.
**Fit timeline** includes the complete cached overview and five minutes of
negative pre-roll for initial placement. Spans wider than 30 seconds draw the coarse, witnessed
overview rather than decoding unbounded exact windows; narrower views request missing measured
tiles on release. During panning the last measured tile or coarse overview stays visible without
issuing a decode for every drag update. Each slice is clipped in its own tile coordinates before translation to the
visible window. Every cached bin covers its measured time span rather than a lone midpoint stick.
Peaks falling within one device-pixel column are merged into a min/max display envelope (mapped
and unplaced audio separately); mapped columns form a filled silhouette preserving relative
amplitude and quiet intervals without bridging uncovered source/timing gaps. No image cache or
source resampling is added. Marker-boundary edits retain the edited marker, zoom and viewport;
explicit history navigation reveals an offscreen marker with only the necessary pan. A released
group drag, including an untimed group's first manual placement, retains that visual position while the replacement map is saved
and verified, then loads fresh measured audio. Numeric move and epoch timing remain keyboard-accessible
alternatives; visual previews never change playback timing. The episode overview is secondary and
can be expanded for navigation outside the current measured window.
Accepted positions are locked by default, with the reference always fixed. Unlock a target before
automatic alignment or advanced timing corrections; locks also prevent reset and epoch splitting.
The default Select tool creates an arbitrary temporary marquee. Only the explicit Move recorder tool
can save a drag as one undoable timing revision. The pointer shows an open hand only over a selectable waveform in an unlocked recorder group in that tool, and
a closed hand during its drag; the fixed reference and empty lane space do not advertise dragging.
An untimed drag is accepted only if the selected source and epoch appear as a mapped placement in
the resulting revision. If an earlier accepted map omitted that source, the manual plan rebuilds
the map while preserving every other accepted placement and mapping; an ineligible or stale source
is refused explicitly rather than producing a no-op revision.
Speaker colors are persistent show defaults with optional episode overrides; an ID-stable initial
palette does not change when another speaker is added. Owned PNG avatars survive image-file removal;
recorder origins use a separate native icon catalog. Unknown speakers remain gray, and names/roles
remain available independently of color. Show hosts seed new episodes only. Saved recorder/source
definitions are show-scoped reusable assignments, not copied recordings; applying them never
silently replaces an existing Primary.

Selection, enabled cycle locators and persistent revision-bound episode IN/OUT are distinct.
The anchored marquee toolbar auditions the selected interval or adds half a second of context,
clamped to media bounds and honoring the current Solo/Mute choices. Cycle repeats separately;
filler loops do not change it. Editing needs no Begin editing action; the app-level
After alignment listening default applies only after a newly accepted alignment is verified.
Transcript labels progress from hidden to sentences, phrases, individual words and words with
start/end timing markers, in one stable row. Zoom and typical timed-word size determine detail;
silence and the current viewport's word count do not inflate it. Adjacent words never merge back
into larger units; overlapping recognition clips label space without changing actual word bounds.
Markers remain approximate recognition boundaries, not editable cut handles.
Clipping at the viewport edge does not invent an additional word boundary.
Full copyable text, explained untimed speech, earlier raw transcripts,
and actionable filler review remain in the inspector. Narrow filler markers become poles or dots
without merging or retiming events.

Header-only metadata inspection/backfill uses the existing decoder and local matching originals,
never implicit cloud downloads. Known facts survive unavailable files. Waveform caches remain
identity/recipe keyed. Processing leaves navigation, playback and appearance changes available;
actual source/timing/range mutations are job inputs. Publication compares scoped media inputs and
merges only its result into the live document, preserving unrelated appearance and review edits.
Changed inputs, competing transcripts or late lock changes refuse stale publication explicitly.

`AlignmentRuntime` resolves the existing identity/availability records, captures an opened-file
witness and lends only witness-bound WWDecode cursors. Access records and witnesses are rechecked
after each read and again after all lanes complete. A failed source is explicitly listed rather than
silently omitted. Accepted placement requires `AlignmentPipeline.verifiedAcceptedMap`, which shares
the aligned-asset renderer's applicability, dependency and exact active-content checks.

`AlignedAuditionWindowReader` reuses `WWRender` and its cursor sample provider for at most five
seconds of 48 kHz listening PCM. The app plays the reference's first decoded channel on the left
and the explicitly selected target channel on the right. Nothing is written to a source, export or
canonical document. Waveform results are discarded on canceled/superseded loads; switching episode,
changing source assignments or undoing/changing the accepted map invalidates or reloads the view.
PCM cursors seek through the existing opened-descriptor gateway with `ExtAudioFileSeek`/`Tell`,
preserving exact source frames and checking identity/cancellation around each seek and on return.
Waveform reads stop at each covered range's exact boundary; aligned listening retains its filter
halo while seeking over skipped prefixes. PCM windows can therefore reach late episode events
without decoding earlier hours. Other codecs retain the 600-second decoded-prefix budget until
their priming and exact seek behavior are established.

File-local adaptive listening uses a separate pitch-preserving multichannel path, not `WWRender`'s
affine SRC. Witnessed reads feed a memory-only nominal PCM converter inside `WWDecode`, then one
direct native TimePitch unit with unchanged channel order. Region-anchored twelve-second processing
blocks and complementary overlap feed the shared five-second listening/derived cache tiles without
cache-cut phase jumps. Unsupported timing remains silence. See
[automatic alignment](automatic-alignment.md#persistence-and-audible-application) for processing
identity, cache revision and native accuracy limits.

Aligned regular listening, production-mix input, and cleanup share prepared PCM
before cuts, recording gain, inserts, or faders. Adaptive tiles use versioned
`WWPCM1` planar little-endian Float32 payloads; compatible legacy JSON tiles migrate
to the binary cache without changing samples. Affine listening also persists
canonical five-second tiles instead of retaining only window-local PCM. Cache keys
include source revision, exact timing context, channel, output format, and render
recipe. A hit never authorizes source access: the existing witnessed decoder and
current-map checks still surround reuse. Original recordings are never written,
replaced, or flattened in place; only app-local derived caches contain rendered audio.
Concurrent listeners share identical preparations, and canceling one listener cannot
cancel another's preparation or a newer same-key derived job.

`WaveformWindowReader.readOverview` is a separate automatic PCM scan after a confirmed episode source
has verified access and the show is saved, or when its overview is missing on alignment open/refresh.
Leaving Setup cancels an unfinished setup scan; opening Alignment checks again. This is not an
expansion of the 30-second exact-window budget. The app caches complete overviews under its local
Derived root, keyed by the source metadata revision, decode format and exact source-frame coverage
ranges. Moving an aligned offset or changing drift without changing covered frames reprojects the
same measured bins rather than rescanning hours of PCM; changing gaps, segment coverage or the
source invalidates that reuse. The complete overview's projected strokes and sorted drawing/hit-test
index also persist in the local Derived store. A small canonical SHA-256 key combines the existing
measured-overview key with the track's group/epoch, current group-map content, file-local correction,
active cut ranges, mapped-only scope, and presentation-recipe revision. It never hashes the recording
again. Unchanged opens restore the prepared display; timing/cut changes rebuild only affected keys,
and Undo can restore the prior cached display. Compact, explicitly little-endian numeric buffers
avoid per-bin property-list decoding and index re-sorting. Checksummed payloads and validated indices
are required; damaged presentation caches rebuild rather than being used. Progress distinguishes
checking saved measurements from a real PCM scan, and completion reports restored/rebuilt displays.
This applies to the alignment overview and channel-specific cleanup Primary overviews.
Reuse still requires current source admission, witness verification,
map applicability and matching decoded format/frame count; only current complete
results publish. It streams every covered sample (no stride sampling),
retains at most 65,536 bins per recording, and refuses more than 24 source hours or 2,048 covered
ranges. Bins never cross an epoch or affine-segment boundary. Unsupported spans remain unplaced;
positive gaps are not scanned or bridged. The runtime rechecks the access record after every chunk,
then witnesses and map currency before publication. Progress also checks the native document
snapshot; cancellation/change returns no partial overview. A failed source has an explicit refusal
and retry action rather than a fabricated preview. The native overview is a coarse,
stored-map navigator, never an anchor picker; clicking covered audio reloads the exact window.
The editable live playhead, or a real **Open Window at Playhead** button per navigable lane,
remain the keyboard/accessibility alternatives. The overview's descriptive accessibility
representation is separate from its mouse-position gesture and the native button action.
Source-duration admission does not bound the map's aligned extent. Gray shading marks portions
outside the exact-window navigator's `-86_400...86_400` aligned seconds; those portions remain in the
overview but cannot be opened as exact windows. The "failed to load" count instead reports source
refusals, not out-of-range timing. Enabled lanes with no measured tile in the visible window report
that absence rather than "Hidden and muted," which is reserved for disabled lanes. The native/AX
action admits only covered points inside the navigation range; a wholly out-of-range lane is
descriptive text, not a navigation button. Stored map values are never clamped.

`VisualAlignmentUITests` uses real generated WAVs and the actual Alignment view, not seeded waveform
pixels or transcript fixtures. Package tests cover extrema, actual witnessed reads, replacement
refusal, exact viewport selection and mixed-rate aligned audio.

## Selected M1 contracts (implemented behind swappable seams)

- **App shell:** AppKit `NSApplication` + `NSDocumentController` with `NSDocument` subclasses hosting
  SwiftUI views (`NSHostingController`). No storyboard and no SwiftUI `DocumentGroup`.
- **Portable show document** (`.wwshow`, UTI `com.brandonmartinez.wavewrangler.show`): one canonical
  JSON value, `ShowDocumentModel` — show, all episodes, recorder groups/epochs, logical source records,
  speakers and per-episode assignments, edit-history skeleton, and an optional
  per-episode `alignment`: append-only versioned time maps plus the accepted revision. Show schema 4
  additionally persists file-local adaptive timing alongside unchanged recorder-clock maps. Schema 1, 2 and 3
  shows open as "needs update" and migrate straight to 4 through `ShowSchemaMigration` (C5: backup, C3
  publication, unknown-newer refusal). An embedded map from a newer time-map schema is refused as
  unknown-newer, never as damaged; a time-map schema bump requires a show schema bump.
- **Canonical library document** (`.wwlibrary`, UTI `com.brandonmartinez.wavewrangler.library`):
  `LibraryModel` — entries (logical show refs, aliases, last-known publication, unavailable records),
  collections/order and recents. It is user work, so it is a canonical document that may live in a
  user-chosen (including cloud) folder, *not* only in Application Support. `WWPersistence.LibraryStore`
  (app adapters `LibraryDocumentStore` / `LibraryLocationController`) publishes it with the same protocol
  as shows, keeps its own prior checkpoints, defaults to the app container and can move to a chosen
  folder (copy → verify → switch; the old copy is kept). "Use That Library" combines both libraries with
  nothing dropped; same-named collections that differ get "(from this Mac)", "(from this Mac 2)", …
  While the folder is unreachable or needs permission (L2/L3), organizing edits go to a device-local
  pending-edits journal ("Edits waiting") and are applied through the base check (ST-36 combine on
  divergence) when it is reachable again; the journal is cleared only after verified publication.
  **Library identity:** schema 2 adds `LibraryModel.libraryID`; edits can't change it. "Grant Access…"
  (`LibraryStore.regrantAccess(to:)`, `LibraryLocationController.regrantAccess(to:)`) saves a new folder grant
  only when the re-selected folder holds the same library ID, then reloads and replays queued edits
  (`reload()` re-adopts after recovery or "Use Other Mac's Version"). Schema 1 libraries are read through
  `LibraryCoder` with an ID derived from their publication ID; their bytes are backed up before the first
  schema 2 publication.
- **Device-local access records** (`WWSources.DeviceAccessRecord`, keyed by `DeviceAccessKey`
  = (ShowID, SourceID), so a duplicated show never shares or overwrites the original's grants): read-only
  security-scoped bookmark, last-known path/volume hints, a metadata-only identity baseline
  (`FileSystemFingerprint`: size, creation/modification dates, persistent file identifier, volume UUID,
  extension-derived type; provisional until the user confirms; dates compare within 1 ms because
  iCloud rematerialization shifts them by ~1e-7 s, other fields compare exactly) and the latest
  observation. Stored as a
  versioned JSON file in Application Support (`FileDeviceAccessStore`); never written into canonical
  documents. Paths, names and bookmarks are hints, never identity.
- **Source gateway** (`WWSources.SourceIO`): the only path to referenced originals. It exposes metadata
  reads, directory listing, read-only bookmark create/resolve, scope start/stop and an iCloud download
  request — no read/hash/preview/decode/write/move/delete API exists. `SecurityScopeLedger` pairs every
  scope start with a stop (`withScopedAccess`). A source-scan test forbids content-capable or mutating
  APIs elsewhere in WWSources.
- **Source engine:** `SourceImporter` (metadata-only, UTType-by-extension audio filter, provisional
  group/epoch/speaker suggestions), `SourceAvailabilityEvaluator` (independent location / access /
  residency / transfer / identity dimensions; denied ≠ missing; stale bookmarks refreshed only when
  identity evidence matches), `RelinkEvaluator` (explicit, user-chosen candidates; confirmation for
  anything but an exact match), `SourceTransferController` (download/progress/cancel/retry/offline) and
  the `@MainActor @Observable` `SourceAvailabilityMonitor` for the Sources UI. The availability setting
  is injected as `SourceAvailabilitySetting(downloadSourcesAutomatically:)` from the app preference.
- **Derived index/cache:** `LibraryIndex` in Caches, rebuilt whenever missing/stale/damaged; never authoritative.
- **Envelope** (`WWPersistence.JSONEnvelopeCoder`, behind `CanonicalDocumentCoding`):
  `{checksum, format, payload, publicationID, revision, schemaVersion}` with sorted keys. Only
  `{format, schemaVersion}` is frozen across versions and is decoded first. Reads refuse, in order:
  malformed version header, wrong format, **unknown-newer schema (before any version-specific field or
  the payload is decoded)**, unsupported older schema, malformed publication header, invalid revision,
  undecodable payload, checksum mismatch, content the model would silently drop, and semantic
  validation issues.
- **Publication identity:** every write gets a fresh `publicationID`. `PublicationStamp`
  `{revision, publicationID, checksum}` identifies what is on disk, and `LibraryShowEntry` records it as
  `lastKnownPublication`. `revision` is **only an ordering hint**: two devices or a restored Version can
  publish the same revision number with different content. Conflict detection compares publication ID
  and checksum.
- **Show identity and copies:** File ▸ Duplicate gives the copy a new `ShowID` (show-scoped episode,
  source and speaker IDs are kept). A Finder/provider copy of a `.wwshow` file keeps the **same**
  `ShowID` as the original. The library lane must surface that collision to the user (for example by
  offering "treat as a copy" with a new ID); it must never silently drop, merge or overwrite either
  document. The checksum is SHA-256 over the canonical payload
  encoding — integrity bookkeeping, not authenticity. Timestamps are ISO-8601 UTC with exactly three
  fractional digits (integer-millisecond rounding keeps decode → encode byte-stable).

### Persistence (WW-009 C2–C6)

- **Publication** (`DocumentPublisher`): P1 candidate validated → P2 validated prior retained in the
  device-local `RecoveryStore` → P3 coordinated base check (exact bytes; mismatch = conflict, nothing
  overwritten, candidate preserved) → stage + flush + verify → P4 replace → P5/P6 independent read-back →
  P7 library acknowledgement → derived index. Failures keep the prior revision and dirty state; a
  post-publication doubt is `acknowledgementUncertain`, never "saved". `ShowDocument` runs the same order
  inside its `writeSafely` override around stock `super.writeSafely` (`AlreadyCoordinated`; P4 is inside
  AppKit). Only Save, Save As and autosave-in-place adopt the new publication.
- **Recovery store** (Application Support, device-local, keyed by logical ID so it survives moves): last
  three validated priors, C2b unpublished edit checkpoints, conflict candidates, migration backups.
  It gives no cross-device recovery.
- **Open:** unknown-newer refuses (never written); damaged files offer a whole validated checkpoint as
  a new untitled copy; migrations preserve the original plus a non-overwriting backup and publish only
  after independent expectations pass.
- **Autosave** (`WWAutosaveEnabled`, `WWAutosaveDelaySeconds` ∈ {1, 2, 5, 10, 30}): the gate is checked
  at `autosavesInPlace`, `scheduleAutosaving()` and every `autosave(withImplicitCancellability:)`.
  OFF schedules nothing, cancels queued automatic work (never a success-shaped `nil`), stays dirty and
  uses AppKit's Save / Don't Save / Cancel review. ON publishes after the quiet delay; if that cannot be
  verified within 1.5 s of the last edit, a C2b edit checkpoint is written at quiescence (0.5 s).
- **Evidence harness** (`Tests/WWPersistenceTests`): ≥100 injected interruptions per boundary
  (P1–P7, L1–L6, M1–M3) plus real `_exit` process kills and two-process conflicts via `wwpersist-probe`.
  Results are appended to `Packages/WaveWranglerKit/.build/persistence-evidence.log`.

## Build and test

### Source onboarding

Completing Import Review explicitly authorizes the included recordings on this Mac.
Enumeration and review remain metadata-only; completion rechecks the selected identities
and captures decoder-owned read-only witnesses before publishing device-local authorization.
Original recordings remain immutable. A failed verification is reported explicitly and
does not grant audio admission. Opening or restoring a show never upgrades source permissions.
Older provisional recordings use **Review Recording Access…** in Recordings & Speakers:
one list and one approval cover the affected episode recordings, with independent identity
checks and named failures for any recording that cannot be authorized.

The Recordings & Speakers sheet resizes in both dimensions; its existing adaptive details
placement and Sources/Speakers divider remain in use. The editor includes a separate
**Ungrouped** section in all four waveform layouts, even before any recorder group exists.
Its metadata-only source references are neither timed nor playable. **Add to Group**
uses existing groups or the shared new-recorder-group form and the normal named Undo/Redo
commands; no waveform, epoch, or alignment is fabricated for a placeholder.

Finder file/folder drops anywhere in the Sources area, including its empty-state card
and existing rows, enter the same metadata-only Import Review as **Import Sources…**.
The native table also accepts file locations at insertion gaps and below its last row;
those drops import references rather than rearranging groups.
Keep accessibility identifiers on the actual controls, not on the drop-region wrapper:
SwiftUI propagates a wrapper identifier over the native table and empty-card identifiers.
The transfer requests file locations, never a file representation that could copy or
materialize recording contents. Review confirmation remains the authorization boundary.
Native recording-row drags use process-local logical IDs scoped to the current show
and episode. Dropping onto a group or one of its rows uses the existing one-step
group-assignment command, retaining epoch numbers, speaker/channel assignments and roles.
Foreign, stale or mixed file/recording drops are refused before any canonical change.

The Import Review recorder-group chooser includes **New Recorder Group…**. Naming
only confirms that row's draft choice; it does not accept its speaker suggestion.
Other review rows can select the draft group. Cancel leaves the episode unchanged;
confirmed Import creates the group and sources in the same Undo step.

Track-blocking alignment, waveform preparation, playback preparation and transcription
use a bounded overlay inside the track viewport instead of duplicated top processing
rows or a bottom waveform status bar. Progress is determinate only when the worker
reports a real fraction. Cancel uses the existing worker cancellation; final verified
timing updates explain why they cannot be interrupted. Track editing, pan/zoom and
navigation shortcuts and conflicting inspector actions are blocked, while transport
Pause/Stop remains available.
Errors and non-blocking readiness notices remain visible, and the workspace's
accessibility value retains the measured-recording status without a visual footer.

The app icon is the complete macOS 16/32/128/256/512 pt, 1x/2x set in
`WaveWrangler/Assets.xcassets/AppIcon.appiconset`, selected for both Debug and Release.
To regenerate from the original square SVG, run
`python3 scripts/generate-app-icon.py "/path/to/logo.svg" "/path/to/new-output-folder"`
with ImageMagick installed. The generator preserves the original and creates a padded, transparent
macOS squircle SVG, an Xcode appiconset, a standard iconset, and an ICNS. Copy the generated
`AppIcon.appiconset` into the app's asset catalog; do not put the source artwork in app resources.

Prerequisites: Xcode with the macOS 26+ SDK (local: Xcode 27; CI: newest stable Xcode 26.x on
`macos-26`). The package uses `swift-tools-version: 6.2` so both toolchains work — do not raise it
without checking the CI image.

```sh
scripts/build.sh            # xcodebuild build, Debug, ad-hoc signed, -jobs 4, DerivedData in .build/
scripts/build.sh Release
scripts/test.sh             # swift test (package, --jobs 4), serialized estimator, segment, pipeline memory, timing and render calibration passes, then xcodebuild test -only-testing:WaveWranglerTests
scripts/test.sh --package-only
scripts/test.sh --ui        # XCUITests only on the current host; use the VM lease pipeline instead on the development Mac
```

`WWRender` uses `-O` in Debug as well as Release. Its scalar clock-correction
renderer can otherwise take longer than one second to prepare one second of
drift-corrected audio, even when Audio Unit rendering easily meets its deadline.
More prebuffered effect output only postpones that sustained underrun. The
optimization is confined to the renderer: the app remains debuggable, and its
signing, sandbox, source-access gates, sample rates, and alignment mathematics
stay unchanged.

The app target generates a UTC millisecond-based build number on every build, including direct Xcode
and test builds. `scripts/build_number.py` writes a derived preprocessor header; Info.plist preprocessing
puts that number in `CFBundleVersion` before signing. The marketing version remains `MARKETING_VERSION`.
An existing derived header prevents repeated or backward clock readings from reusing that build number.
No tracked version file or Git state changes during a build.

Library, episode, and Settings window subtitles show the version/build read from the running bundle;
the standard About panel uses the same metadata. `scripts/build.sh` prints the completed bundle's
identity and exact path. On a build-and-launch handoff, report this number and verify it against the
running window. Use stable window accessibility identifiers in UI tests rather than exact titles,
which now include build identity. Run `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-build-number.py`
to check generation independently without creating source-tree bytecode.

### Source maintenance and historical qualification

The [2026-10-20 source baselines](source-tree-baselines.json) pin the maintained
estimator, segmenter, renderer, time-map and decoder source/test trees after
American English cleanup. They also pin the SHA-256 of each unchanged historical
freeze record. The shared test-only `WWTestSupport` helper checks these baselines
and includes edited/untracked files when calculating a tree identity.

These pins are source-integrity checks, **not new DSP qualification**. The
historical measurements, seeds, gates and vendored engine bytes are unchanged.
Old one-shot holdout entry points now refuse changed historical source trees
before generating cases. A future qualification needs its own explicit freeze,
approval and evidence; do not replace old measurement records or clear that guard.

First-party names use American English. Platform spellings such as
`Task.isCancelled` and the legacy serialized `"cancelled"` case/key remain
unchanged so OS integration and existing documents/access records stay compatible.

### Local speech diagnostics

The isolated `ww-tiny-pcm-probe` is a **headless experiment**, not app inference. Standard
package tests exercise missing, wrong-size and wrong-hash model refusal, descriptor I/O
failure and nonlocal/unknown filesystem rejection without a model;
the model-backed test is explicitly disabled unless `WW_TINY_MODEL_PATH` is set. To run
the executable against a separately approved, locally supplied `ggml-tiny.en.bin`:

```sh
swift run --package-path Packages/WaveWranglerKit --scratch-path .build/swiftpm --jobs 4 ww-tiny-pcm-probe --model "$LOCAL_TINY_MODEL_PATH"
```

It opens only that path read-only without following the final symlink, disables dataless
provider materialization for the open/read thread, and refuses dataless descriptors and
descriptors whose filesystem is not confirmed locally mounted. Checked, bounded `pread`
refuses I/O errors and short reads instead of aborting; it reads exactly 77,704,715 bytes,
checks the descriptor before/after, and hashes the bytes against
`921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f`
before loading them from memory into the pinned CPU library. It generates two seconds
of 16 kHz mono PCM with two inference threads and at most 16 decoded tokens. Output is
aggregate only; segment timing availability is **not** word timing or accuracy.
Never put model bytes in the repo. The legacy diagnostic `SpeechInference.infer` still refuses even for a
selected primary. It is not the live cleanup transcription entry point
(`PrimarySpeechSourceIssuer` and `LocalWhisperRecognizer`), and this command does
not establish production source binding, sandbox offline proof or media consent.

### GUI testing

For headless functional XCUITests, build on the development Mac and run the
signed Products inside the [macOS VM GUI hosts](ui-test-vm-hosts.md) through
their own lease helpers. `scripts/test.sh --ui` launches on the **current
host** and must not be run on the user's desktop outside an approved window.
Do not fall back to the Mac mini when a VM is unavailable. Physical-device
performance, audio hardware, and unsupported virtualized GPU behavior need a
concrete hardware-specific reason and separate approval.

**Current refinement qualification discrepancy (Xcode 27.0, macOS 27.0):**
the unchanged `AlignmentInspectionUITests.testBlockedRecoveryContrastAudit` passes on the
Retina VM (1024x768 logical, 2x) but fails on the second VM at 1920x1200, 1x, for the
recording-recovery description, including with sampled black-on-white pixels. Seven isolated
SwiftUI and native `NSTextField` text comparisons pass on that same 1x VM, so the cause remains
unresolved and is not established as a framework-wide defect. Delivery of this refinement was
explicitly approved against the passing Retina gate with this discrepancy documented.
Audit criteria and waivers are unchanged; this is not a general exemption from 1x testing.
The later PoC scope decision defers this broad qualification to the explicit Accessibility
plan; a passing feature gate does not resolve or qualify this discrepancy.

Per-PR GUI selection and the reviewed conditional flake-quarantine policy (currently only the
#218 broad synthetic Library contrast test) are documented in [GUI flake quarantine](gui-flake-quarantine.md).
`scripts/test.sh --ui` now selects the 10-test **PoC** feature gate, not the entire UI bundle.
Explicit `--ui-profile=regression`, `--ui-profile=accessibility`, and
`--ui-profile=performance` preserve broader coverage separately. Functional assertions,
source safety, persistence, Undo/Redo, and ordinary keyboard shortcuts remain covered;
broad accessibility/appearance audits are deferred, not waived or reported as passing.
See the [plan selection and VM pipeline](gui-testing.md) for focused selectors and
audit admission. Manual-only CI triggers are unchanged.

Environment overrides: `WW_JOBS` (default 4) and `WW_DERIVED_DATA` (default `.build/DerivedData`).
`WW_SEGMENT_SWEEPS` selects the WW-017 segment pass. `1` runs calibration, the floor sweep and edge silence; `0` runs
calibration only. It defaults to `1` locally and to `0` when `CI=true`; the CI workflow also sets `0` explicitly, to
keep the job well inside its timeout. With the sweeps off, the always-on cheap test
`committedRecordsReproduceTheReportedCalibration` still re-checks the committed floor and edge-silence records. Run
the full `scripts/test.sh` locally before handoff so the sweeps themselves run.
All outputs live under the gitignored `.build/` inside your worktree.

Settings: macOS 26.0 deployment target, arm64 only, Swift 6 language mode with complete strict
concurrency, App Sandbox + user-selected read-write files + app/document-scoped bookmarks, hardened
runtime, ad-hoc signing (`CODE_SIGN_IDENTITY=-`, no team). Outgoing-network permission supports
explicit, hash-verified Whisper model downloads in Settings; there is no network-server entitlement,
telemetry, or audio/transcript upload. Inference remains local and offline.

`WaveWranglerTests` is an **unhosted** bundle: it links the package products and reads the app's
`Info.plist`/entitlements from the source tree, so running it never launches the app.

### Live-provider (iCloud / two-device) tests are opt-in

Tests that need a real file provider (live iCloud Drive, `brctl`, or a second Mac) are **skipped by
default** in `scripts/test.sh`, the UI suite and CI. Opt in with `WW_LIVE_PROVIDER_TESTS=1` (#146):

| Test | Also needs |
|---|---|
| `ProviderTrialTests` (WWSources: `observedICloudTrial`, `frozenHoldoutCycles`) | — |
| `HoldoutICloudTrialTests` (WWPersistence, M1-DUR-024) | `WW_HOLDOUT=1 WW_ICLOUD_TRIAL=1`, or `scripts/holdout.sh --icloud` |
| `scripts/dur025/run.py` (M1-DUR-025 two-device harness) | `WW_DUR025_REMOTE=user@host` (or `--remote`), `WW_SAME_ACCOUNT_ATTESTED=1` (the operator attests the same Apple account; `main()` refuses to start without either), and a second Mac on that account |

Without the flag, each one skips with a message naming the flag. Opt in only with the user's grant
for live iCloud trials (synthetic data in `WaveWrangler-M1-Synthetic-Trial/` only). The deterministic,
simulated provider tests always run by default: simulated NSFileVersion conflict versions
(`LibraryProviderConflictTests`), the source identity and timestamp tolerance tests, and the
simulated iCloud download paths. The product's provider protections are unchanged; only the live
tests are gated.

### Concurrency limits

- At most one `xcodebuild` per session and at most three concurrently on the host, each `-jobs 4`
  with its own DerivedData (the scripts do this).
- Run test suites serially per lane (`scripts/test.sh` disables parallel xcodebuild testing).
- Don't run UI tests or launch the app without GUI permission; take the chosen host's GUI lock first
  (one agent drives each host's screen at a time) and release it right after.

### Local host prerequisite

`xcodebuild` requires Xcode's first-launch system components. If it fails with "failed to load a
required plug-in … run `xcodebuild -runFirstLaunch`" (check with `xcodebuild -checkFirstLaunchStatus`),
someone with admin rights must run `sudo xcodebuild -runFirstLaunch`. Agents must not do this without
explicit user permission. `scripts/test.sh --package-only` works without it.

## Preference keys

App-level `UserDefaults` keys live in `WWOrganizer.PreferenceKey`; `AppPreferences(defaults:)` reads them with
the product defaults applied, so a missing key always means the default. The Settings window writes them.

| Key | Type | Default | Read by |
| --- | --- | --- | --- |
| `WWAutosaveEnabled` | Bool | `true` (autosave ON) | Persistence (autosave policy), show save status |
| `WWDownloadSourcesAutomatically` | Bool | `true` (downloads ON) | Sources (availability/download) |
| `WWTextSizePercent` | Int 100–200, step 25 | `100` | All WaveWrangler windows (in-app text size, CMD-20) |
| `WWSettingsLastPane` | String (`general`/`sources`/`transcription`) | `general` | Settings window |
| `WWSelectedWhisperModel` | String (`baseEnglish`/`turbo`) | `turbo` (preserves legacy bookmarked choice) | App-wide transcription settings |
| `WWTranscriptionWorkers` | Int 1–4 | `1` | Shared transcription settings and app-wide ASR admission |

### Transcription worker admission

`TranscriptionSettings.shared` owns one `TranscriptionWorkerPool` across all episode windows.
Jobs capture their selected 1–4-way speaker fan-out, with sequential, source-anchored chunks within
each Primary. The pool admits an entire Primary worker including aligned rendering, inference and
source reverification. Its FIFO continuations are cancellable and release on success, error and
cancel/grant races. Increasing the limit wakes queued tracks; lowering never interrupts active
tracks, but refuses new starts until occupancy is below the new limit. Versioned configuration
prevents a delayed settings task from restoring an old limit. The conservative default is one;
two is a reasonable manual starting point on high-memory machines, not a measured optimum.

Whisper contexts and per-context CPU backends are independent. The native bridge sets the shared
log callback once and serializes context initialization (which initializes upstream shared FFT/backend
tables), then releases the lock **before** inference. No live context is shared between workers.
Each inference uses its captured 1/2/4/8-thread configuration; Accelerate/Metal may use additional
internal resources. The 1–4 worker limit is not an OS-process count or a strict total-thread count.
The app-wide pool accounts for verified weights, inference, requested threads, Metal slots and the
actual multichannel renderer envelope from `AlignmentPipeline.adaptiveAudioReservationBytes`.
See the [CPU/Metal qualification and budgets](../research/apple-silicon-transcription.md);
Core ML/ANE remains deferred.

`TranscriptionChunkPlanner` advances one sample-exact 48 kHz core at a time inside that admission.
The candidate has a 28-second core and clipped one-second left/right context (30 seconds maximum).
Only its final four core seconds plus right context are examined in 10 ms RMS hops. The latest
qualifying low-energy run (at least 300 ms, below both -50 dBFS RMS and 20 dB below the local
90th-percentile RMS) supplies a center boundary, clamped to the fixed maximum. Otherwise the fixed
boundary remains. Selected PCM is trimmed to its retained right context, never silence-compacted;
the next iteration re-renders overlapping context. The planner retains only frame coordinates, not
whole-recording PCM or a precomputed episode-wide boundary array. Midpoint ownership compares
window-relative frame coordinates; aligned/source timing still uses the accepted lane map.
The production saved recipe includes the versioned chunk policy. The old fixed-window reference
remains available to synthetic and opt-in public comparisons, not as an extra UI setting.
See [measurements and timing limits](../research/transcription-chunking.md).

`CleanupTranscriptionReporter` aggregates unique completed cores by speaker, publishes the full
active-speaker set, and sequences packets so delayed concurrent UI callbacks cannot roll progress
backwards. Initial global queue wait is excluded from the first processing-speed estimate.
Chunk totals remain zero/unknown until the final core, and the UI omits an unknown denominator.
Results are sorted back into plan order, all sources/maps are rechecked, and only the caller may
publish the complete, current episode result.

Worker tests cover all four caps, shared independent jobs, queued cancellation, configuration changes
and error release. Hosted generated-audio tests force overlapping Primaries and out-of-order finishes,
and verify serial-equivalent source anchors plus all-or-nothing failure/cancellation. Native controls
are explicitly opt-in with `WW_LOCAL_ASR_CONCURRENT=1`, `WW_LOCAL_ASR_MODEL` and
`WW_LOCAL_ASR_PUBLIC_WAV`: 2/4 actual contexts rendezvous inside their CPU-graph abort callbacks, then
must reproduce serial text and timestamps. They use caller-authorized public audio, never private
episode recordings.

## UI seams between lanes

The library/workspace UI talks to other lanes only through these protocols. Keep them stable; extend
additively and update this table.

| Seam (file) | Implemented by | Contract |
| --- | --- | --- |
| `DocumentStatusProviding` (`Workspace/DocumentStatus.swift`) | `ShowDocument` via `Workspace/ShowDocumentStatus.swift` (maps `DocumentStatusModel` → `WWOrganizer.DocumentSaveState`) | Observable `saveStatus` (D1–D16 + checking/unknown/read-only). "Saved" only for persistence's verified-on-disk states. `NativeDocumentStatusObserver` remains the honest fallback for any document without a status model. |
| `DocumentStatusActionHandling` (same file) | Persistence (optional) | Handles popover/message-bar actions (Resolve…, Try Again, Save a Copy Elsewhere…, Cancel Save…). |
| `LibraryPersisting`, `LibraryLocationControlling` (`Library/LibraryServices.swift`) | `Library/PersistenceLibraryBackend.swift` over persistence's `LibraryDocumentStore` + `LibraryLocationController` | Load, then apply edits as **transforms** on the canonical value (never whole snapshots) and follow `currentLibrary`; L1–L5 (+ damaged) state, pending-edits status, ST-34 quit text, copy → verify → retire moves, “already has a library” combine, combine summaries incl. queued edits not carried. |
| `LibraryEntryObserving` (same file) | `InMemoryLibraryBackend` (per-show “as of last open” details from shows opened this run) | Device-local, rebuildable; open/locate/reveal by show identity. `InMemoryLibraryBackend` also backs UI-test fixtures. |
| `SourceCommandHandling` (`Commands/SourceCommands.swift`) | Sources UI | File › Import Sources…, Relink Source…, extra Source-menu items, and optional Edit › Delete / Move Up/Down hooks for the Sources/Speakers tables (return a title only while your table has focus). `SourceCommands.handler` defaults to a placeholder that changes nothing. |
| `AutosavePolicyConnection` (`Settings/AutosavePolicyConnection.swift`) | Persistence `AutosavePolicyController` | The Settings toggle binds to `AutosavePolicyController.shared.isEnabled` (`WWAutosaveEnabled`/`WWAutosaveDelaySeconds`); `isConnected` is true only while that controller is the source of truth. |
| `SetupContainerView` (`Workspace/SetupContainerView.swift`) | `EpisodeSetupContent` | Direct, typed construction from the shared document store, episode identity, and environment text scale. Episode identity resets view-local state; no mutable factory registration or placeholder is required. |

`EpisodeAlignmentModel` owns document-facing presentation and asynchronous job admission.
`AlignmentWaveformCache` owns bounded tile retention, coverage, eviction, and atomic reprojection
without re-decoding retained bins. `AlignmentAudioPlayback` owns the audio engine, nodes, scheduled
buffers, gains, and playback clock. The model retains cancellation/generation guards, verified-map
checks, and the bounded playback producer. `AlignmentSourceAccess` distinguishes an absent
device-local record from read/refresh failures; failures propagate to the operation's visible error
state, while cancellation remains cancellation.

Episode windows: `EpisodeWindowController` hosts `ShowWorkspaceView(state:)` with a fixed
`ShowWindowState.boundEpisodeID`, restored by logical episode ID. Opening the same episode reuses its
window unless a new window was explicitly requested. Deleting its episode never retargets that editor.
Each editor, including duplicate views, has a distinct AppKit restoration identifier. Document
restoration creates the archived episode's controller rather than reusing an arbitrary first window.
Archives include the show ID; foreign or missing episodes are refused with a local diagnostic, not
rebound into a valid editor. Older archives without a show ID still require episode membership in
the loaded document. Track edits and Undo/Redo retain the editor's bound logical episode ID.
The states are registered for menu routing (`CommandRouter`); all windows for a show share one
`ShowDocument`/`ShowDocumentStore`, save status, and document undo manager.

Library selects shows and opens their documents with `display: false` to manage live episodes in
`LibraryShowDetail`, not cached last-open summaries. A windowless document controller retains each
browsed show in AppKit's save/quit lifecycle after its last episode editor closes; no hidden window is
created. Library's episode panel routes Undo to that show's undo manager, while collection edits retain
Library's separate history. `Close Show` calls `canClose` before closing the whole document.
Edits go through `ShowDocumentStore.apply(_:coalescing:_:)` with the user-facing names in
`WWOrganizer.UndoActionName` for organization edits.

Library ordering: `LibraryUIStore` (backed by the pure, unit-tested `WWOrganizer.LibrarySession`) loads at
launch, never writes before load / after a failed load / while read-only (L4/L5), queues show-open bookkeeping,
refreshes titles only after a coherent save (D1), and undoes only what an action changed.

UI-test launch arguments (Debug builds; synthetic data only): `-WWUITestResetPreferences YES`,
`-WWUITestLibraryFixture lib100|empty`, `-WWUITestOpenShow <name>` with `-WWUITestShowEpisodes <n>`, and
`-WWForceReduceMotion YES`.

### Mixer model and persistence (schema 9)

`WWCore.Episode.mix` holds optional `EpisodeMixState`; absence is neutral:
0 dB input/speaker/Master gain, centered pan, and no inserts. Schema 1-8 shows
require the existing consented C5 migration with an exact-byte backup. Migration
changes no timing, transcripts, cuts, assignments, or history. Older-schema
payloads carrying mix state are refused, even when the state is neutral; newer
schemas remain read-only/refused by the usual format gate.

`RecordingInputGain` is scoped by episode, `SourceID`, and explicit zero-based
channel. `settingInputGain(_:for:in:)` refuses unknown channels rather than
inventing channel 0. A caller may resolve verified mono media using the existing
`ChannelReference.resolvedChannel(channelCount:)` helper before making the edit;
unresolved multichannel media needs an explicit choice. Known channel counts
bound stored gains; unknown counts do not invent media facts. Resetting input
gain to 0 removes only that key. A later observed channel count that contradicts
a stored gain is refused atomically, like a conflicting channel assignment.
Changing a stated channel or Primary never moves gain: the newly selected
recording/channel uses its own gain, while the speaker
retains its fader, pan, and inserts. Speaker removal discards only that episode's
speaker strip, not recording gains; source removal discards only that recording's
gain entries, not the speaker or Master chains. Normal value-snapshot Undo
restores the removed state.

Build strips from `Episode.speakerAssignments`, not the sparse mix array. Use
`mix.state(for:)` for a speaker's neutral fallback. The sole production input is
the selected authorized Primary/channel; Backups are not summed. Source
authorization and accepted-timing admission remain runtime responsibilities.
Input gain precedes speaker inserts; `SpeakerMixState.gainDB` and `pan` follow
them. `MasterMixState.gainDB` follows the summed Master inserts. All stored gains
are finite in -96...24 dB; pan is finite in -1...1. Pan law, metering, mute/solo
listening policy, and processing availability are not canonical mix data.

`AudioUnitSlotID` is stable and unique across an episode's speaker/Master buses.
Insert array order is processing order. `AudioUnitComponentIdentity` stores
unsigned FourCC type/subtype/manufacturer codes; only `aufx` and `aumf` effects
are supported. Slots retain bypass, optional diagnostic product/version strings,
and exact opaque `documentState` bytes even when the unit is missing. State is
an XML or binary property-list dictionary from the unit's document state, never
a keyed object archive. `nil` requests default state; empty/malformed state is
refused. Limits are 16 MiB per slot, 64 MiB per episode, 64 inserts per bus,
64 levels of state nesting, and 1024 UTF-8 bytes per diagnostic string. State
numbers must be finite. No discovery result, live unit, editor, or observer is
serialized.

The pure `ShowDocumentModel` operations `settingMix(_:in:)`,
`settingInputGain(_:for:in:)`, `settingSpeakerMix(_:in:)`, and
`settingMasterMix(_:in:)` return whole validated values or throw
`DomainError.invalidMix`/the existing reference errors without mutation. Editing
a strip's insert array supports add/remove/reorder/bypass/state recall as one
atomic edit. Invoke these inside the existing shared
`ShowDocumentStore.apply(_:coalescing:_:)` with a user-facing action name and a
control/episode-specific coalescing key. The store owns Undo/coalescing; the pure
operations do not append duplicate history entries or create a second store.

`EpisodeProcessingInputs` / `hasSameProcessingInputs(as:in:)` include mixer
state, source/timing dependencies, working range, and active manual cuts.
`EpisodeMediaInputs` deliberately excludes mix state, preserving raw waveforms,
accepted timing, and raw transcripts across mixer edits. Processing comparisons
normalize sparse neutral entries and control order but preserve insert order
and exact state bytes. This is only a canonical dependency snapshot, not source
authorization or the complete offline recipe: the processing layer must freeze
verified source identities, resolved channels, format, and latency/tail policy.
Audio hosting, playback/offline rendering, mixer windows, and export UI are
separate layers; this foundation does not launch UI or read original media.

### Native mixer processing and PCM rendering

`WWMix` is downstream of `WWRender`, which remains pure and unchanged.
`AlignmentRuntime.mixerRecipe` freezes `EpisodeProcessingInputs`, the confirmed
Primary routes, actual gateway-witnessed `RawSourceIdentity` and
`FormatInterpretation`, explicit resolved channels, signed edited program frames,
format, pan law, and seek/latency/tail policy. Neither a recipe nor a witness is
an access grant. `productionPCM` reuses the accepted-map, witnessed
`sourceAuditions` readers and the shared manual-cut timeline, always with cuts
collapsed, with input gain disabled at that boundary. It checks frozen identities,
current access records, actual formats, accepted timing, and complete windows
before returning. Effects never receive a source URL. Offline jobs also recheck
admission during their latency/tail drain, not just during source reads.

The initial qualification is native arm64, 48 kHz planar Float32, mono speaker
inserts and stereo Master inserts/output. Only `aufx` and `aumf` effects with a
main input and a single output bus supporting the exact requested format are
admitted. Unused auxiliary/sidechain inputs are disabled after document-state
recall and verified disabled before rendering; external sidechain routing is
not supported. Format failures identify the effect, the required 48 kHz
mono/stereo layout, and the failed configuration step. Unknown
multichannel Primaries refuse rather than selecting channel 0. Multiple speakers
cannot share the same Primary/channel (which would double one microphone).
An episode assignment without a confirmed Primary is an explicit error, not a
silent strip or automatic Backup substitution.

`MixerProcessor.load(recipe:progress:)` asynchronously loads ordered slots.
`MixerAudioUnits.installedEffects()` discovers effects without loading editors.
The Add menu groups effects into alphabetized manufacturer submenus, with
alphabetized effects inside each and an Unknown Vendor group for missing names.
Loading has a 30-second bound and responds to cancellation; a late completion
does not replace a canceled/failed instance. Out-of-process loading is requested,
and `unitStatuses()` exposes the actual `isLoadedInProcess` result. Apple
low-pass units were observed as `AUAudioUnit_RemoteV2`, out of process, on the
local macOS 27 arm64 headless test host. This is not a universal AUv2 isolation
or release-distribution claim. No sandbox or library-validation exceptions are
added. Sandboxed app-host/editor compatibility and physical device monitoring
remain separate qualification gates.

macOS may display a "lower security settings" compatibility warning when a
third-party Audio Unit is not declared sandbox-safe. This is not a request to
disable SIP or change system-wide security settings. Requesting out-of-process
hosting does not guarantee that every legacy unit runs sandboxed. WW does not
add the audio-unit-host sandbox exception or disable library validation to
suppress the warning. Cancel rather than approve a warning for an effect you
do not trust. See Apple's
[Audio Unit Host Sandboxing Guide](https://developer.apple.com/library/archive/technotes/tn2312/_index.html)
and [out-of-process hosting guide](https://developer.apple.com/documentation/audiotoolbox/debugging-out-of-process-audio-units-on-apple-silicon).

One serial processor retains each unit across all producer windows:

```text
authorized timed/cut mono PCM -> recording/channel input gain
  -> ordered speaker inserts -> explicit parallel-path delay alignment
  -> speaker fader/equal-power pan -> stereo sum
  -> ordered Master inserts -> Master gain/meters -> prepared stereo PCM
```

The sum is not divided by the number of audible speakers. Center pan contributes
1/sqrt(2) to each output; hard left/right contributes unity to that side.
Finite output above unity is retained, not clipped or normalized;
`MixerMeter` exposes peak/RMS, clipping, and headroom. Live gain/pan targets use
sample-clocked 480-frame (10 ms) linear-amplitude ramps, continuous across chunks.
Mix edits never enter estimators, ASR, raw waveform cache keys, or original files.
Diagnostic source/comparison audition retains its routing/attenuation and applies
the saved recording/channel gain without speaker/Master effects. A recording-gain
change invalidates already-prepared diagnostic windows; restart that audition.

`EpisodeAlignmentModel.playProductionMix(interval:)` explicitly selects
production listening. `playEnabledTracks` remains diagnostic/source audition;
neither pane visibility nor source Solo/Mute implicitly changes that choice.
The production adapter schedules already-rendered stereo on the existing owned
`AlignmentAudioPlayback` engine, with no second playback engine. Production
separates one-second **raw** source-preparation windows (at most five queued
windows plus the currently consumed window) from 512-frame DSP blocks. Startup
primes this raw queue (or the remaining program, when shorter), then revalidates
source access, identity, and timing before starting output. A separate worker
continues that verification throughout playback, including final draining and
fully prefetched short programs; any failure invalidates DSP immediately.
Bookmark/File Provider and full-map checks must never block the sub-100-ms
processed-output horizon. Each newly prepared source window still performs its
normal witnessed-read and current-map checks.
The pipeline retains one pure accepted-map calculation keyed by the complete
media/timing inputs, registered source revision tokens, and format revision.
Persisted activation and read admission share the decoded map, dependency
verification, and canonical identity calculation while those values are equal.
Reuse additionally requires the same retained immutable map-history snapshot;
re-created values recompute rather than equating distinct canonical bytes such
as positive and negative zero.
Every read still checks the live accepted revision and exact ready coordinator
identity; shutdown, changed publications, sources, formats, placements, or
same-revision map/correction content cannot reuse an old admission. This cache
contains no source grant, bookmark resolution, original-file witness, or PCM,
and does not skip the read gateway or ongoing source surveillance.
`ProductionMixPlayback` reads a value snapshot of live controls on **every**
512-frame block, including latency drain; no gains or effects are baked into the
raw cache. Document edits synchronously update controls or invalidate incompatible
workers. The processed scheduling horizon is 4096 frames
plus at most one in-flight block: at most 4608 frames / 96 ms of prepared audio,
not seconds of producer buffering. Before starting the device clock, production
queues at least 2048 verified output frames (or the complete final short program).
The 2048-frame start lead plus this prefill and any one-block rounding still fit
the same 4608-frame bound. No underrun deadline runs while the initial buffer is
being prepared. This absorbs cold Audio Unit startup work without adding seconds
of pre-rendered control latency; real missed deadlines after startup still stop
explicitly and preserve the clock long enough for the handler to retain the playhead.
Both regular and production refill run outside the main actor. One serial output
queue owns the shared AVFAudio graph, schedules buffers, and accounts for consumed
audio using the player's native sample timeline, not a `Date` estimate or an
early wall-clock margin. Final draining uses `.dataPlayedBack` completion.
The UI independently polls progress and prepared meters, so transcript layout,
accessibility work, and other UI stalls do not hold up audio refill or its watchdog.
The generated responsiveness assertion changes a fader after source preparation,
observes its ramp on the very next block's first sample without resetting the
processor, and verifies the horizon stays below 100 ms.
Effects render on the serial worker, not in the hardware callback. This is
**buffered monitoring**, not a claim of immediate/hardware-input low-latency
processing: audible control response includes that bounded prepared horizon,
the 10 ms ramp, scheduling jitter, and device latency. Meters describe prepared
PCM, not a sample-synchronized hardware tap. Missed deadlines stop explicitly
instead of scheduling substitute silence.

Production underruns emit one `WWAUDIO_UNDERRUN v=1` error in the
`com.brandonmartinez.wavewrangler` / `AudioPlayback` unified-log category.
The bounded per-playback snapshot contains scheduled/consumed frame counts,
time since the last scheduled packet, raw queue occupancy, and last/maximum/
in-flight timings for source preparation, waiting for raw PCM, source verification,
control publication, DSP, and output scheduling. Producer wake delay excludes
the requested pacing sleep. The output queue captures this evidence before
stopping the graph or waiting for the UI handler; late enqueues use the same
one-shot report. No audio, source identifiers, paths, or vendor state is retained
in diagnostics, and no per-block log/event history is collected.

`WW_PRODUCTION_TIMING_TESTS=1` enables the hosted source-preparation timing
diagnostic and sustained drift-plus-inserts qualification. Run those on a leased
VM; the recorded run with unoptimized `WWRender` is the negative control.
`WW_WAVES_SYNTHETIC_TIMING=1` enables a separate headless, generated-PCM-only
benchmark of installed RCompressor, TrueVerb, and L1 effects. A physical-host run
requires explicit approval for that specific benchmark; it never opens source
recordings, editors, audio output, or saved vendor state.
Leased-VM regressions cover adaptive timing, cold/warm caches, live controls,
source changes, and main-actor transcript-layout stalls. Those functional results
do not establish acoustic latency or physical-device performance.

`MixerOfflineRenderer.render(recipe:isCurrent:input:sink:)` uses independent
instances of the identical processor. It accepts at most five seconds of input
per window and uses 512-frame native render calls. Its sink receives bounded,
finite stereo windows with absolute edited `firstFrame` and exact frame counts,
never delivery files. The sink must stage results and publish only after a
successful return; cancellation, stale dependencies or a failed final check
invalidates every previously delivered window. The app adapter is
`AlignmentRuntime.renderProductionOffline`. It requires a live document-currency
closure as well as the built-in source-access/identity rechecks.

Reported, nonnegative integral-frame unit latencies are summed along serial
chains. Shorter speaker paths receive the difference from the longest path;
the common speaker latency plus Master latency is then removed exactly once.
No engine PDC is assumed or also applied. Generated unequal-latency paths and a
Master delay verify impulse coincidence and exact program length. Fractional,
changing, nonfinite or over-budget latency refuses. Vendor misreported latency
is not automatically measured/corrected; each additional unit needs
qualification rather than a DAW-grade compensation claim.

Seeking/restarting creates independent reset instances. `MixerRenderPolicy`
defaults to zero preroll and exact-program tail truncation, a deliberate
cold-start policy rather than transparent seek equivalence. Optional bounded
preroll requires real authorized preceding PCM, never fabricated program data.
`includeReported` drains the maximum serial speaker tail plus Master tails;
nonfinite, changing or over-budget declared tails refuse. Program output is
exactly `programFrames.count`, plus the explicit reported tail when selected.
Missing program frames do not become EOF. Native transient
`CannotDoInCurrentContext` retries are limited to four attempts at the same sample
time; other statuses fail immediately. Unwritten/nonfinite output refuses.
A malicious/hung in-process vendor render call cannot be forcibly interrupted;
bounded host loops do not constitute plug-in process isolation.

#### Layer-3 controller and transaction contract

Bind docked and detached views to **the same**
`EpisodeAlignmentModel.mixer: EpisodeMixerController`, never construct another
controller, processor, transport, source grant, or Undo store for detachment.
The controller exposes observable loading/ready/playing/failure state, bounded
speaker/Master meters and unit isolation/latency status. Its `processor` provides
`parameters(slot:)`, `editor(slot:)`, and validated `setParameter` access.
`MixerUnitEditor.requestViewController()` runs on the main actor and may return
nil; use the generic descriptors in that case, not a fabricated native editor.
Observe `instanceRevision` to dismiss/rebind vendor editors when a new processing
instance replaces a prior seek/play session. Controller `mutedSpeakers`,
`soloedSpeakers`, and `masterMuted` are separate ephemeral production-listening
choices, shared by docked/detached views; they do not alter source-audition Solo/
Mute or canonical mix state. Muting ramps post-insert gain to zero while effects
continue processing, so an unmute does not reset their history.

Use normal `ShowDocumentStore.apply(_:coalescing:_:)` operations for input gain,
fader/pan, bypass, reorder, add/remove and Undo. `synchronizeControls()` applies
current gains/pan without resetting effects. Input/routing/timing/cut or insert
topology/state replacement is a stop/reload boundary; stale controllers must
never write over a changed Primary, deleted slot, or Undo-restored state.
Live gain changes are accepted against the frozen media/cut/slot dependencies;
offline rendering instead freezes every gain and opaque state byte.

Generic edits go through
`setParameter(slot:address:value:coalescing:)`, which captures
`AUAudioUnit.fullStateForDocument` and commits the validated opaque state through
the existing document store. Await `beginEditorObservation(coalescing:)`
**before** displaying a vendor editor. It establishes an unchanged-state baseline
so opening an editor does not dirty default/nil state or rewrite unchanged
serialized slot bytes, then polls the complete document state every
200 ms, including opaque changes with no parameter notification. The Audio Unit
parameter observer only increments an atomic revision; it never calls an actor,
allocates a task, does I/O, or writes the document from the callback.
`captureAndPersist(coalescing:)` refuses stale slots and invalid, oversized or
nonfinite vendor state without dropping it or silently reverting to defaults.
State restore requires complete dictionary read-back agreement; vendors that
normalize/refuse supplied state may be conservatively rejected.

The UI integration must await `captureAndPersist` at **Save, Undo/Redo and close
barriers**, suspend editor polling, perform the normal document operation, and
restore/reload from the resulting document before resuming editing. On editor
close, await `endEditorObservation()`; do not rely on close as the first dirty
capture. Serialize these barriers with new generic edits, dismiss stale native
editors on reload, and surface any refused capture/transaction. Polling is not a
synchronous Save interceptor; those command/lifecycle hooks belong to layer 3.
Do not stop/reprepare a controller with uncommitted native-editor state.
One shared coalescing key represents an edit gesture/burst, and the store ends
coalescing normally on Save/Undo or an unrelated edit.

Generated PCM plus Apple-unit headless tests live in `WWMixTests`.
Docking, detachment, native editor interaction, sandboxed host behavior, and
full transport/device qualification require the later leased VM/approved host
gates; these package tests do not authorize UI launches or user-media access.
The user-approved integration correction in `ForbiddenAPITests` distinguishes
the labeled in-memory `.remove(at:)` operation from forbidden unlabeled POSIX/
file-store `remove` calls. It does not exempt a cache file or relax any content,
gateway, mutation, hook, or thread token. Its regression scans the actual
`AdaptiveAudioPCMCache` and injects forbidden probes into that same source.

#### Docked/detached mixer and document barriers

`ShowWindowState.mixerPresentation` owns presentation only. Both `MixerView`
surfaces bind `state.alignmentModel.mixer`; detaching constructs no audio engine,
runtime, source grant, mix copy, or Undo manager. The originating editor retains
its alignment model across legacy destination changes. A late runtime startup
must reuse an already-attached model instead of replacing the editor's controller.
`EpisodeBottomPaneContent` adds Review/Mixer to the existing device-local view
state; the serialized review visibility/height keys and all review accessibility
identifiers remain compatible. Detached windows are not document window
controllers: they cannot keep a windowless document alive. They route commands
and Undo through their originating state and close with that editor.

`MixerOperationQueue` serializes capture/parameter/load operations across actor
awaits. Suspending editor observation cancels **and awaits** the poll before
final capture. The final capture retains the editor coalescing key, then ends
coalescing. Native baseline comparison ignores only property-list dictionary
serialization order; original slot bytes are retained until the native state
actually changes. Domain/recipe equality still preserves exact serialized bytes.
No-op captures do not create Undo steps or dirty default state.

`ShowDocument.mixerTransactions` serializes document operations with generic edits.
Save (including autosave), Undo/Redo, Revert, and document/editor close hide
native editors, suspend polling, drain capture, and only then enter AppKit's
ordinary operation. Save keeps the same current processor and resumes polling
after completion. Undo/Redo and restart dismiss stale editors and invalidate the
old processor; the next editor/play prepares from the resulting document.
Transport Stop alone preserves native state and observation. Refused capture
aborts the document operation, leaves the saved slot unchanged, and exposes an
error. A failed editor can be retried or explicitly discarded after confirmation.
While a native editor is open, incompatible source/timing/chain changes outside
the mixer barrier are explicitly refused rather than racing its state.

Effect-editor ownership is exclusive per episode across originating windows.
`handoffEditors(to:)` runs inside the document queue, awaits capture/closure of
the prior editor, and loads the new owner's instance from the resulting mix.
Changed captures invalidate nonediting same-episode instances, never another
episode's processors. Insert/play restart barriers scope teardown to their
episode; Save, Undo/Redo, and document close retain document-wide barriers.
Capture failures expose confirmed discard/reload on the mixer surface, including
for a native editor that cannot close successfully. No capture is required to
perform an explicitly confirmed discard.

`ShowDocumentStore.canEdit` includes actual viewing mode and mapped read-only
status at the mutation boundary. Both recording gain surfaces use its shared
gain operation. A refused recovery restore never marks its offer restored, so
a subsequent verified Save cannot delete that unapplied checkpoint.
`alignmentWorkspaceDidDisappear()` stops diagnostic audition while preserving
deliberately detached production and the retained originating model. Buffered
monitoring still stops explicitly if UI/device scheduling misses its deadline.

`MixerHostedTests` uses generated media and Apple low-pass units for shared
ownership, two episodes/documents, input-gain/Primary identity, production
transport, ordered slots, missing/read-only handling, native/generic recall,
and controlled poll-versus-close/Save overlaps. `MixerUITests` exercises the real
bottom-pane and auxiliary windows. `MixerReviewRegressionTests` covers refused
recovery, same-episode editor handoff, failed native capture/discard, episode
isolation, viewing mode, and workspace-disappearance policy. Run hosted/UI cases only through the
[leased VM pipeline](gui-testing.md); the unhosted operation-queue tests and
static plan checks launch no editor.

## Conventions

- **Originals are immutable.** No code path renames, moves, deletes, overwrites or writes into a
  referenced source, and nothing silently substitutes a same-named file.
- **Logical IDs are identity.** Paths, filenames and bookmarks are location/permission hints only.
- **Unknown is a state.** Use `Knowledge<T>.unknown` / explicit `unknown` enum cases; never a sentinel.
  Unknown, denied, missing, changed, unverified, residency and transfer states stay distinct.
- **Metadata-only means zero content access.** OFF/metadata-only paths make no content, hash, header,
  preview, decode or download requests. M1 has no decode or audio analysis at all.
- **Refuse, don't repair.** Readers refuse unknown-newer, damaged or inconsistent documents and leave
  the file unchanged; never downsave.
- **Honest state.** Never show "saved" without coherent disk truth; dirty state comes from the undo
  manager/change count.
- **Pure operations.** Domain changes are `WWCore` functions that return a new value or throw a
  `DomainError` without partial mutation; the app registers undo with a user-facing action name.
- **Tests use synthetic fixtures only**, generated in memory or in temporary directories. Never read
  user recordings or sample folders.
- **Accessibility is part of done:** keyboard reachability, VoiceOver labels, visible focus and
  non-drag alternatives for every core workflow.
