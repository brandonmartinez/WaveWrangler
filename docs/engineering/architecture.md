# Architecture

WaveWrangler uses AppKit `NSApplication`, `NSDocumentController` and
`NSDocument`, hosting SwiftUI with `NSHostingController`. There is no storyboard
or SwiftUI `DocumentGroup`. Package modules contain reusable domain and
processing logic; the app owns native UI and lifecycle integration.

## Source map

| Location | Responsibility |
| --- | --- |
| `WaveWrangler/App`, `Document` | Launch, canonical document store, AppKit save/close/restoration integration |
| `Library`, `Workspace`, `Commands`, `Settings` | Library/workspace presentation, bound episode windows, routing, preferences |
| `Sources` | Metadata review, recordings/speakers, grants, relink and setup |
| `Alignment`, `Shared` | Accepted-map runtime, transport, waveform/projection, clips and timeline tools |
| `Cleanup` | Local transcription orchestration, words, filler/manual review and cuts |
| `Mixer`, `Export` | Native effects/console ownership and document-owned delivery interface/jobs |
| `WaveWranglerTests` | Unhosted app-adapter tests; no application launch |
| `WaveWranglerHostedTests`, `WaveWranglerUITests` | Native app integration and real UI execution on leased VMs |

## Package boundaries

All package paths below are under `Packages/WaveWranglerKit/Sources`.
`Package.swift` is the authoritative dependency graph.

| Module | Contract |
| --- | --- |
| `WWCore` | Logical IDs, Sendable domain values, strict validation and pure whole-value edits |
| `WWPersistence` | Canonical envelopes, coordinated publication, migration, recovery, library and autosave policy |
| `WWSources`, `WWEpisodeSetup` | Metadata-only source services, device access records, availability, import/relink/setup |
| `WWDecode` | Sole source-content opener, witnessed read-only streaming decode and format interpretation |
| `WWTimeMap` | Exact source/group/aligned clock maps and explicit unsupported intervals |
| `WWCommonEdit` | Manual-cut/program composition, placement inverses, exact clip envelopes and production projection |
| `WWAlignEstimate`, `WWAlignSegment` | Pure acoustic proposal/abstention and discontinuity segmentation; never clock approval |
| `WWAutoAlign` | Decoded-buffer spectral fingerprints, precise affine/adaptive acoustic evidence; no I/O |
| `WWDerived` | Append-only map history, derived keys/assets, bounded cancellable jobs and currency checks |
| `WWAlignPipeline` | Headless gateway/admission/analysis/acceptance/render orchestration |
| `WWRender` | Pure channel-consistent affine SRC from caller-provided decoded buffers |
| `WWMix` | Program routes, native effects, latency/tail policy, live controls and offline PCM rendering |
| `WWExport` | Bounded delivery codecs, conversion/loudness/job publication and bundled notices |
| `WWSpeech`, `WWWhisperNative` | Source-bound local speech inference and pinned native CPU/Metal engine |
| `WWWordEvaluation`, `WWCutPolicy` | Pure word/proposal evaluation and protected-cut admission, not recognition or permission |
| `WWOrganizer` | Presentation catalogs, preference keys, library session/organization and menu shortcuts |

`wwpersist-probe` is a synthetic headless persistence fixture tool.
`ww-tiny-pcm-probe` is a separately opted-in generated-PCM diagnostic, not app
inference. Test-only helpers and synthetic modules do not expand production
source access.

## Three kinds of state

**Canonical user work** lives in the complete show catalog and `LibraryModel`.
`ShowDocumentModel` is the domain operation value; the native store's explicitly
named `residentModel` is only a projection of loaded episodes, never catalog
membership or save authority. `ShowCatalogRevision` retains every ordered slot,
including exact immutable stored records for unloaded episodes.
**Device-local state** includes grants, location hints, view preferences and
recovery checkpoints. **Derived state** includes waveforms, decoded/rendered
tiles and indexes, all rebuildable. Never use a cache to repair missing
canonical work or grant permission.

`EpisodeMediaInputs` captures recording/timing dependencies without mixer or
supplemental edits. `EpisodeProcessingInputs` adds cuts, mutes, production range,
arrangement and normalized mix dependencies. Names/order or sparse neutral
controls should not invalidate unrelated raw media work. A dependency snapshot
is not complete source admission: live witnesses, formats and access generations
still need runtime checks.

## Native ownership and seams

All windows for one show share one `ShowDocument`, `ShowDocumentStore`, save
status and document Undo manager. `ShowDocumentStore.apply(_:coalescing:_:)`
applies validated transforms, not stale whole-model snapshots.
Library organization has its own canonical store and Undo history.
Episode windows share residency pins and load tasks. Unpinned current and Undo
revisions archive/evict without changing logical identity; UUID revisions and
generation checks reject stale asynchronous results. Catalog membership,
reordering, source inventories and Library summaries use the complete index.
The serial persistence lane also admits episode loads and archival; it does not
create a worker pool proportional to catalog size.

An `EpisodeWindowController` has a fixed `ShowWindowState.boundEpisodeID`.
Opening an existing episode normally reuses its window; an explicitly new
window has independent presentation and restoration identity. Deleting the
episode never retargets that editor. Restoration validates show/episode
membership and refuses foreign/missing identities. A browsed show may remain
windowless but retained in AppKit's save/quit lifecycle.

`EpisodeAlignmentModel` owns document-facing presentation and job admission.
`AlignmentRuntime` owns source/map admission and processing adapters.
`AlignmentWaveformCache` owns bounded measured tiles and atomic reprojection.
`AlignmentAudioPlayback` owns the shared engine, serial output queue, scheduled
buffers and native playback clock. `EpisodeMixerController` owns the episode's
production processor and native-state integration.

Docked/detached mixer and review surfaces reuse their originating model.
Detachment creates no second transport, permission registry or document.
Auxiliary windows do not keep a windowless document alive and close with their
originating editor.

| Seam | Role |
| --- | --- |
| `DocumentStatusProviding`, `DocumentStatusActionHandling` | Honest verified-save state and optional recovery/retry actions |
| `LibraryPersisting`, `LibraryLocationControlling` | Transform-based canonical library edits and verified location changes |
| `LibraryEntryObserving` | Rebuildable last-open observations, not live canonical editing |
| `SourceCommandHandling` | Focus-aware import/relink and source-table command routing |
| `AutosavePolicyConnection` | Connects Settings to the shared persistence policy |
| `SetupContainerView` | Typed setup construction using shared store and logical episode identity |

App-level preference keys are centralized in `WWOrganizer.PreferenceKey`;
`AppPreferences` applies defaults. View state stays device-local, while audible
edits belong in the show. Malformed stored configuration should surface an
error, not silently rewrite user preferences.

## Change boundaries

Follow [persistence and source access](persistence-and-source-access.md) for
document/native-state barriers; [audio processing](audio-processing.md) for
runtime/cache dependencies; [program timeline](program-timeline.md) for
coordinates; and [transcription](transcription.md) for job/provenance limits.
Changing a kernel's output interpretation requires its recipe/version and
dependent cache identities to change, not a bypass around stale-result checks.
