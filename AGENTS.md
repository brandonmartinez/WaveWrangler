# Working on WaveWrangler

Read this file before changing the repository. Human setup starts in
[CONTRIBUTING.md](CONTRIBUTING.md); technical contracts start in the
[engineering index](docs/engineering/README.md).

## Scope and worktree safety

- Work from the current request and current code. Do not restore retired team
  orchestration, milestone kickoffs, issue dispatch, or historical work queues.
- Inspect the working tree before editing. Re-read affected files and preserve
  existing changes. Stop on conflicting ownership instead of overwriting work.
- Keep changes surgical and complete across directly dependent callers.
  Do not fold unrelated fixes into a requested documentation or product change.
- In a shared checkout, agree on nonoverlapping write scopes. Do not stage
  another worker's files or change branches underneath another session.
- Follow current authorization for commits, branches, pushes, PRs and merges.
  Neither an old plan nor an engineering example grants those permissions.

## Route work to the owning layer

| Concern | Start here |
| --- | --- |
| Domain values and validated edits | `Packages/WaveWranglerKit/Sources/WWCore` |
| Canonical coding, migration, recovery, publication | `WWPersistence`; app `Document/` |
| Bookmarks, source availability, import and relink | `WWSources`, `WWEpisodeSetup`; app `Sources/` |
| Source-content opening and format interpretation | `WWDecode` |
| Exact clocks, cuts, insertions, clip envelopes | `WWTimeMap`, `WWCommonEdit`; app `Shared/` |
| Acoustic proposals and accepted-map orchestration | `WWAlignEstimate`, `WWAutoAlign`, `WWAlignSegment`, `WWAlignPipeline` |
| Derived identities, jobs and cache publication | `WWDerived` |
| Rendering, mixing, native effects and transport | `WWRender`, `WWMix`; app `Alignment/`, `Mixer/` |
| Local recognition and transcript review | `WWSpeech`, `WWWordEvaluation`, `WWCutPolicy`; app `Cleanup/`, `Settings/` |
| Delivery encoding and export lifecycle | `WWExport`; app `Export/` |
| Library, windows, menus and settings | `WWOrganizer`; app `Library/`, `Workspace/`, `Commands/`, `Settings/` |

Use existing helpers and typed operations before adding another abstraction.
Package modules must not depend on the app. Pure kernels must not gain I/O,
UI, approval APIs or concurrency merely to simplify a caller.

## Language and state

- Use Swift 6 concurrency/isolation and Sendable value snapshots. Keep domain
  state in value types and native ownership in small focused controllers/actors.
- Prefer composition and shared helpers over inheritance or duplicated logic.
- Use American English for first-party identifiers, comments, docs and UI.
  Preserve platform APIs, serialized keys/cases, third-party bytes and quotations.
- Represent unknown, denied, missing, changed, unverified, residency and transfer
  separately. Do not replace them with sentinels or success-shaped defaults.
- Surface typed failures through the established visible error/logging path.
  Cancellation stays cancellation; do not suppress cleanup or capture failures.

## Recordings, documents and native state

- Originals are immutable: never write, rename, move, replace or delete a
  referenced recording. Names, paths and bookmarks are not identity.
- Metadata-only paths do zero content/hash/header/preview/decode work.
  Opening/restoring a show does not authorize audio access.
- Source content opens only through `WWDecode/SourceDecoder` and its
  package-access `SystemSourceContentIO.swift` gateway. Preserve read-only
  descriptor checks, local residency, no dataless materialization and witnesses.
- A cached waveform, PCM tile, recipe or saved witness is not a grant. Recheck
  current access generations, identity, format, channels and map applicability.
- Keep portable canonical state, device-local permissions and disposable
  derived state separate. Do not add absolute media paths to portable shows.
- Unknown-newer schemas refuse before payload interpretation and remain
  untouched. Schema changes require explicit migration, exact-byte backup,
  independent expectations, strict decoding and recovery coverage.
- Publish through the existing verified save protocol. Do not label an
  unverified publication or an older saved snapshot as the current model Saved.
- Apply validated domain transforms through `ShowDocumentStore` with named
  Undo/coalescing. Do not hold an Undo group open across an await.
- All windows for one show share its document/store/Undo manager. Episode
  editors stay bound to logical IDs; deletion never retargets another episode.
- Capture native Audio Unit document state before Save/autosave, Undo/Redo,
  close and incompatible replacement. Refused capture must abort visibly.
- Capture before entering AppKit autosave's file-access context; an idle,
  pre-captured save must start synchronously. Keep save publication independent
  of the mixer edit queue and preserve later edits as dirty.
- Balance user experience, actual/perceived performance and write safety.
  Even a one-second stall disrupts repeated edits: keep routine persistence off
  the UI thread, allowing narrowly scoped blocking when save/native-state safety
  requires it. Never trade verified publication for apparent responsiveness.
- Detaching a mixer/review view must not create another runtime, processor,
  permission ledger, document copy or Undo store.

## Jobs and audio

- Bound workers, memory, buffers and retained results explicitly. Share admission
  across windows; do not size estimator jobs from all available CPU cores.
- Capture relevant inputs and revalidate after awaits and before publication.
  Use generations/tokens where equal-byte Undo/restore can otherwise cause ABA.
- Preserve unrelated live edits. Reject stale source, timing, slot or transcript
  results instead of replacing the complete live model with an old snapshot.
- Cancellation must release permits, close cursors and join owned work.
  Shut down derived jobs before releasing source access.
- Keep original-source, aligned, edited dialogue, final program and review-only
  display coordinates distinct. Use shared projection/inverse helpers.
- Acoustic proposals are not clock authority. Keep measured, quiet-derived,
  anchor-guided and estimated timing distinguishable.
- Production Mix and Source Audition have distinct routing and edit semantics.
  Never derive production audio from waveform display bins.
- Preserve real-time bounds, explicit underrun refusal, source surveillance,
  effect latency/tail policy and native-state barriers when optimizing.
- Inference is local. Explicit model download permission is not media-upload
  permission, and historical media consent is not current authorization.

## Validation and environment

- Follow [testing](docs/engineering/testing.md): package logic first, unhosted
  app adapters next, leased-VM hosted/UI behavior when the change requires it.
- Use established scripts and bounded jobs; coordinate the total host budget.
  Keep the editing app's DerivedData separate from every test build.
- Use `umask 022` for tests; protect specific logs separately if necessary.
  Capture bounded scalar leaves before Swift Testing assertions on heavy models.
- Ordinary hosted/UI tests run on ready, exclusively leased macOS VMs.
  An unavailable VM is a blocker, not permission to use the desktop or Mac mini.
- Physical-host execution needs a requirement virtualization cannot verify,
  an explanation, and approval for that specific host/run.
- Do not run builds with sudo, alter security protections, install tools, fetch
  models/media, or launch experiments as an incidental validation step.
- Use generated fixtures by default. Live-provider, external-media, model-backed
  and holdout checks require their own explicit opt-in and authorization.
- Source maintenance pins are not historical DSP qualification. Do not rewrite
  frozen records, seeds, gates or failed results to make a changed tree pass.
- Report actual executed identities and pass/fail/skip counts when presenting
  test evidence. Compilation and deferred audits are not runtime passes.

## Documentation updates

| If the change affects... | Update... |
| --- | --- |
| Setup, installation or contributor workflow | `CONTRIBUTING.md`, `getting-started.md` |
| Cross-cutting agent safety or routing | This file; keep Copilot instructions a short entry point |
| Module responsibilities or native ownership | `architecture.md` |
| Persistence, permissions, migration or Undo | `persistence-and-source-access.md` |
| Timing, DSP, transport, effects or caches | `audio-processing.md` and the focused timing reference |
| Recognition, model admission or provenance | `transcription.md` |
| Test selection, runner or host operation | `testing.md`, `gui-testing.md`, `ui-test-vm-hosts.md` |
| Delivery formats, metadata or licensing | `export-codecs.md` |
| User-visible behavior | Relevant product guide as well as the technical contract |

Keep engineering docs current and focused. Remove superseded instructions;
do not append phase diaries, obsolete ownership tables or machine-local run logs.
