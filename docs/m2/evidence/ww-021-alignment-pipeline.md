# WW-021 / WW-023 headless alignment pipeline: evidence

Refs #24 #18 #19. This covers the package module `WWAlignPipeline`. There is no app UI in this unit;
WW-022 will present the states described here. All the evidence is from **synthetic fixtures only**:
there was no real recording, no network and no GUI.

## What the module does

| Step | Entry point | Guarantee |
|---|---|---|
| Plan | `AlignmentPipeline.plan` | Lists every recorder group and epoch of the episode and picks one reference. A source is admitted only when its location is known, availability is ON, the user explicitly authorized content work (`ContentWorkAuthorization`) and its revision is registered. Every other source gets a typed `SourceIneligibility` and **zero decode work** (proven against the recording content gateway). |
| Analyse | `AlignmentPipeline.analyse` | Probes admitted sources (`SourceFacts`, a derived result), then for each target epoch decodes one bounded excerpt per side through `SourceDecoder.withDecodingCursor`. It mixes channels to mono, decimates by an integer factor to ≥ 8 kHz, and runs the frozen `WWAlignEstimate` API. The result is stored as an `EpochAnalysisRecord` keyed by every M2-C5 component (sources and revisions, format revision, recipe, estimator identity, map revision of record = none, asset version). Proposals are `acousticConsistentProposal` only. Abstentions keep the estimator's evidence and resolve to WW-014 states (weak / disconnected / ambiguous / silent / periodic / discontinuous → U7/U8), each with its remedies. |
| Accept / manual | `AlignmentPipeline.accept`, then `activate` | Accepting a current proposal (as `manual`, basis `acceptedAcousticProposal`), numeric entry (ppm/offset), anchors (≥ 2, fitted exactly) or a reject (U8 `notAttempted`) builds an `AlignedTimelineMap`. It appends it as a new revision through `MapHistory` (marking dependents stale); `activate` publishes through the unchanged C3 coordinator path. A proposal measured against another reference or source revision is refused. A prior `clockApproved` epoch is refused, never carried forward, and nothing in the module can construct `ClockApproval` or `.clockApproved` (`ForbiddenAPITests`, `AcceptanceTests`). |
| Render | `AlignmentPipeline.renderAlignedAssets` | For the accepted, active and applicable map, streams `WWRender` output for every same-group channel, segment by segment, into `DerivedAssetStore` (app cache only), with recipe, renderer and asset versions in the key. Every group renders at one episode-wide output rate. That rate is decided by the WW-050 `OutputSettingsPolicy` over the probed `FormatInterpretation` of every renderable source: by default 48 kHz, or `matchSources` when configured. The decision and its reasons are in the report, and the policy version and rate are in each segment's recipe name. Cached assets stay binary32; the policy's sample format applies at M4 export. Each segment re-checks the accepted revision, cancellation and shutdown before it starts, and the coordinator's commit-time currency check discards late results. Export stays blocked (M4). |
| Resolve | `EpochAlignmentState.resolve` | Maps plan, accepted map, records and failures to the inspection-spec states, with the accepted map as the decision of record first. |

## Resource bounds

- `AlignmentPipelineConfiguration.concurrency` is clamped to 1…4 (default 2) and is never derived from
  the processor count (`ForbiddenAPITests` bans `activeProcessorCount`/`processorCount` in the module).
- One `ResourceGate` per pipeline admits probes, analysis units and group renders FIFO against both the
  permit count and a byte budget (default 512 MiB). A unit larger than the whole budget is refused before
  any decode. Each analysis unit's admission covers its estimated working set: decimated buffers, FFT
  scratch and decode chunks.
- Decode is streaming. A `DecodingCursor` yields bounded chunks, and the decimator keeps only its filter
  history and the decimated output, then stops decoding at the end of the needed range.
- Nothing runs on the main actor or main thread (the recording gateway counts main-thread reads; every
  suite asserts zero). There are no semaphores, threads or Dispatch primitives in the module.

### Memory measurement (serialized heavy pass)

`PipelineMemoryTests` runs only with `WW_PIPELINE_HEAVY_TESTS=1`, serialized in `scripts/test.sh`. It
analyses three recorder groups, each with two 7-channel, 48 kHz, 75-minute synthetic sources: the
reference; target 1 at rate 1.0001 with a +1.25 s offset; and target 2 at rate 0.99995 with −2.5 s. That is
14 channels × 75 minutes per group, at the default configuration (concurrency 2, budget 512 MiB, 600 s
excerpt, ±120 s search). A dedicated thread samples `TASK_VM_INFO` every 2 ms; `getrusage` gives the
process peak.

Run on 2026-10-06, Apple M5 Max (18 cores, 128 GB), macOS 27.0.1, Swift 6.4, debug build:

| Measure | Value | Bound asserted |
|---|---|---|
| Process peak resident (`ru_maxrss`) | 337 MiB (45 MiB before the run) | < 1 GiB |
| Sampled peak physical footprint | 297 MiB | < 768 MiB |
| Gate peak active / peak estimated bytes | 2 / 420 MiB | ≤ concurrency / ≤ budget |
| Frames decoded / reader opens | 373,194,752 / 10 | — |
| Proposals | target 1: +100.03 ppm; target 2: −50.02 ppm | published, no failures |
| Wall time | 103.8 s | — |

Under the default budget, two 75-minute analysis units (≈ 420 MiB estimated each) cannot both be admitted,
so heavy units run one at a time, with a probe alongside. Analysis wall time therefore scales with the
number of groups. The estimate is conservative: the measured growth was about 290 MiB.

## Tests

Package suites (`swift test --filter WWAlignPipelineTests`, 46 tests in 12 suites; synthetic only):

- **End to end:** decode → propose → accept → activate → render → map change invalidates the renders.
  Rendering the same revision again reuses every segment and opens nothing.
- **Abstention** (7 cases): silent, unrelated (weak), periodic, echo (ambiguous), offset step
  (discontinuous), short reference (disconnected) and an unreachable search range (insufficient coverage).
  Each resolves to its WW-014 state and remedies, with full evidence stored.
- **Eligibility:** OFF, unauthorized, unregistered and unlocated sources are planned out with typed
  reasons and never reach the decoder. With every source OFF, the whole run is metadata only (zero opens
  through the recording gateway). Turning a source OFF before rendering skips its channels without opening
  it. A source rewritten since registration is refused at the probe, and a source changed after analysis
  drops its proposal.
- **Acceptance:** versioned revisions; numeric entry; anchors; reject → U8; undecided epochs; refusal of a
  stale proposal and a `clockApproved` prior; `activate` refusing a revision the document does not accept;
  a source-scan check against forging approval.
- **Concurrency:** deterministic late analysis and late render (the map changes while the job is held at
  commit) with negative controls that publish; cancel mid-decode; cancelling the caller at commit;
  shutdown during render; bounded admissions and readers; a shared gate; over-budget refusal.
- **Output settings:** mixed 48 / 44.1 kHz sources render at the policy's 48 kHz, and the resampled 44.1 kHz
  target lands on the timeline truth (relative error < 0.02). All-44.1 kHz sources render at 48 kHz by
  default and at 44.1 kHz under `matchSources`. When nothing is renderable there is no decision and no
  open.
- **Guards** (`GuardTests`): direct tests for the defence-in-depth checks the end-to-end suites cannot reach.
  These are `admitted` for registered but ineligible sources; a probe refusing another format or envelope
  revision; `build` refusing a proposal measured on another source revision; analysis decode stopping within
  one chunk of the needed range; refusal of an inapplicable map before any open; and the per-segment
  map-revision, shutdown and cancellation checks.
- **Units:** `ResourceGate` (cap, budget, FIFO, refusal, cancelled waiter), `boundedMap`, configuration
  clamps and recipe names, and the decimator (factors, frequency response, invariance to chunking).
- **Heavy pass:** `PipelineMemoryTests` (above).
- `ForbiddenAPITests` scans `Sources/WWAlignPipeline` with no exceptions: file, content, hashing,
  mutation, decode-internals, gateway, derived-store, coordinator test-hook, processor-count,
  main-actor and Dispatch/thread APIs. Includes a scanner self-test.

Every suite also passes under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. Bounded-work tests assert upper
bounds only, because overlap depends on how many cooperative threads exist. `ResourceGateTests` prove
deterministically that the cap is reached.

## Mutation checks

Each mutation was applied alone to `Sources/WWAlignPipeline`, then the module was rebuilt and
`swift test --filter "WWAlignPipelineTests|ForbiddenAPITests"` was run (runner: session-local `mutate.py`;
it waits while the 1-minute load is ≥ 24; 420 s per run). Run on 2026-10-06 at the policy-integration head.
**31 of 31 killed.** The 9 survivors of the first run (M04, M06–M09, M20, M21, M25, M27)
are killed by `GuardTests`, which was added for them.

| ID | Mutation | Result | Killed by |
|---|---|---|---|
| M01 | OFF availability ignored | killed (4) | Each ineligible source is planned out, never opened, and shown as a Setup block; Turning a source OFF before rendering skips its channels without opening it; With every source OFF the whole run is metadata only; `admitted` never lends a location or revision for an ineligible source, even one that is registered |
| M02 | consent ignored | killed (4) | Each ineligible source is planned out, never opened, and shown as a Setup block; Turning a source OFF before rendering skips its channels without opening it; With nothing renderable there is no decision and no output rate, and nothing is opened; `admitted` never lends a location or revision for an ineligible source, even one that is registered |
| M03 | registration ignored | killed (2) | Each ineligible source is planned out, never opened, and shown as a Setup block; `admitted` never lends a location or revision for an ineligible source, even one that is registered |
| M04 | admitted skips check | killed (1) | `admitted` never lends a location or revision for an ineligible source, even one that is registered |
| M05 | verify token skipped | killed (1) | A source rewritten since registration is refused at the probe and blocks its epoch until re-registered |
| M06 | verify format revision skipped | killed (1) | A decoder interpretation from another format or envelope revision is refused, whatever the revision token |
| M07 | render map-currency check removed | killed (1) | Between segments a render stops when the accepted map is no longer its revision |
| M08 | render cancellation check removed | killed (1) | Between segments a render stops when its task is cancelled |
| M09 | render shutdown check removed | killed (1) | Between segments a render stops once the coordinator has shut down |
| M10 | gate permit cap removed | killed (3) | A cancelled waiter leaves the queue without being admitted; the next waiter is still served; At most `permits` units are admitted; a release admits the next waiter; The gate is shared: a unit already admitted elsewhere leaves analysis one slot |
| M11 | gate byte budget removed from fits | killed (1) | Admitted bytes never exceed the budget, and waiters are served strictly in arrival order |
| M12 | over-budget refusal removed | killed (hang) | suite hangs (a waiter is never admitted, or an over-budget unit waits forever); 420 s timeout |
| M13 | analysis admits zero bytes | killed (1) | A unit whose working set exceeds the whole memory budget is refused before anything is decoded |
| M14 | boundedMap ignores limit | killed (1) | Peak in-flight never exceeds the limit |
| M15 | concurrency clamp max removed | killed (1) | Defaults and clamps |
| M16 | budget floor removed | killed (2) | A unit whose working set exceeds the whole memory budget is refused before anything is decoded; Defaults and clamps |
| M17 | recipe omits excerpt | killed (1) | Every result-changing parameter is part of the recipe names |
| M18 | clockApproved prior accepted | killed (1) | A persisted clock approval is shown refused, never carried forward, and replaced only by an explicit decision |
| M19 | early noCurrentProposal removed | killed (1) | A source that changes after analysis drops its proposal: shown pending, never accepted |
| M20 | isCurrent ignored | killed (1) | `build` refuses or withholds a proposal measured on another revision of either source, even if handed it directly |
| M21 | isCurrent ignores revision tokens | killed (1) | `build` refuses or withholds a proposal measured on another revision of either source, even if handed it directly |
| M22 | resolver accepted-map-first skipped | killed (4) | A persisted clock approval is shown refused, never carried forward, and replaced only by an explicit decision; A synthetic episode is proposed, accepted, rendered, re-timed and re-rendered; nothing on the main thread; Every decision yields only timelineReference or manual provenance, versioned and derived from the prior revision; Undecided epoch carries its current proposal unaccepted (U3); an explicit reject returns it to U8 and stays rejected |
| M23 | resolver clockApproved shown as proposal | killed (1) | A persisted clock approval is shown refused, never carried forward, and replaced only by an explicit decision |
| M24 | remedies: proposal loses accept | killed (1) | A synthetic episode is proposed, accepted, rendered, re-timed and re-rendered; nothing on the main thread |
| M25 | decoder does not stop at needed range | killed (1) | An analysis decode stops within one chunk of the frames it needs, never reading the rest of the file |
| M26 | activate ignores coordinator revision | killed (3) | A map change that lands while aligned segments commit discards them all; skipping the currency check would publish them; A synthetic episode is proposed, accepted, rendered, re-timed and re-rendered; nothing on the main thread; activate refuses a revision its document does not accept; nothing runs after shutdown |
| M27 | render ignores map applicability | killed (1) | Rendering refuses an accepted map that no longer applies to the episode, before opening anything |
| M28 | accept ignores shutdown | killed (1) | activate refuses a revision its document does not accept; nothing runs after shutdown |
| M29 | render uses lowest source rate, not the policy decision | killed (2) | All-44.1 kHz sources: the default renders at 48 kHz, `.matchSources` at 44.1 kHz; the rate keys the assets; Mixed 48 / 44.1 kHz sources render at the policy's 48 kHz; the 44.1 kHz source is resampled onto the timeline |
| M30 | policy configuration ignored | killed (1) | All-44.1 kHz sources: the default renders at 48 kHz, `.matchSources` at 44.1 kHz; the rate keys the assets |
| M31 | recipe omits policy version | killed (1) | Mixed 48 / 44.1 kHz sources render at the policy's 48 kHz; the 44.1 kHz source is resampled onto the timeline |

## Known limits and risks

- The proposal for an epoch is one affine segment, extrapolated from the analysed excerpt to the whole
  epoch hull. Every source in an epoch is placed at group-clock 0.
- Each target epoch is estimated against the reference only (single pair, mono mix of one source per
  side); there is no cycle-consistency check across targets.
- Analysis decodes sequentially from frame 0, with no seek. For a centred 600 s excerpt of a 75-minute
  file, that decodes about 57 % of the reference and target.
- Estimator CPU runs on the cooperative pool, limited only by the gate's permits.
- Sources without probed facts are omitted from maps, and unsupported (U7/U8) epochs are not rendered.
  Epochs carrying an accepted acoustic proposal (U3) are rendered.
- Accepting and activating are two steps. Activating an older accepted revision is allowed, and renders
  follow the coordinator's active revision.
- The memory bound is measured for analysis. The aligned-asset render was exercised on short fixtures
  only; a full 75-minute render (debug ≈ 0.1 s per channel-second) is unmeasured.
- New public WWDecode API: `SourceDecoder.withDecodingCursor` / `DecodingCursor` (the streaming path the
  pipeline uses; `ChunkPump` now copies channels in bulk). WWRender's provider pulls samples, while the
  frozen decoder pushes them into a synchronous sink. A bridge between the two would either buffer whole
  sources or block a cooperative thread, so the cursor has to live inside the WWDecode gateway. It changes
  the `m2-freeze-decode` pinned trees.

  At the coordinator's direction, the cursor is split out to `brandonmartinez/wwdecode-pull-cursor` (based
  on main). The Mac lane records the dated `m2-freeze-decode-2` there: calibration, repin and registry
  entry, with its own single holdout later. Until that merges,
  `DecodeFreezeTests.decoderAndHarnessTreesMatchTheFreezeRecord` fails on this branch by design. The rev-1
  holdout (#202) remains the evidence for the rev-1 tree.
