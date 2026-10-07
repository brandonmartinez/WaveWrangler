# WW-021 / WW-023 headless alignment pipeline: evidence

Refs #24 #18 #19. This covers the package module `WWAlignPipeline`. There is no app UI in this unit;
WW-022 will present the states described here. All the evidence is from **synthetic fixtures only**:
there was no real recording, no network and no GUI.

## What the module does

| Step | Entry point | Guarantee |
|---|---|---|
| Plan | `AlignmentPipeline.plan` | Lists every recorder group and epoch of the episode and picks one reference. A source is admitted only when its location is known, availability is ON, the user explicitly authorized content work (`ContentWorkAuthorization`) and its revision is registered. Every other source gets a typed `SourceIneligibility` and **zero decode work** (proven against the recording content gateway). |
| Analyse | `AlignmentPipeline.analyse` | Probes admitted sources (`SourceFacts`, a derived result), then decodes bounded excerpts through `SourceDecoder.withDecodingCursor`. It mixes channels to mono, decimates by an integer factor to ≥ 8 kHz, and runs the frozen `WWAlignEstimate` API. For multiple target epochs the estimator receives the target and its peers in one request, so shared windows can close cycles and declared restarts carry `restartedEpoch`. A planned peer that cannot be probed or admitted blocks the cycle instead of silently reducing the cohort. Decimated 20 s peer excerpts are shared within a run under the memory admission; no peer is decoded twice per run. The result is stored as an `EpochAnalysisRecord` keyed by every M2-C5 component (reference, target and peer sources/revisions, format revision, cohort/recipe, estimator identity, map revision of record = none, asset version). Proposals are `acousticConsistentProposal` only. Abstentions keep the estimator's evidence and resolve to WW-014 states (weak / disconnected / ambiguous / silent / periodic / discontinuous / cycle-inconsistent → U7/U8), each with its remedies. |
| Accept / manual | `AlignmentPipeline.accept`, then `activate` | Accepting a current proposal (as `manual`, basis `acceptedAcousticProposal`), numeric entry (ppm/offset), anchors (≥ 2, fitted exactly) or a reject (U8 `notAttempted`) builds an `AlignedTimelineMap`. It appends it as a new revision through `MapHistory` (marking dependents stale); `activate` publishes through the unchanged C3 coordinator path. An accepted proposal keeps **only its measured interval**: frames outside it stay `outsideCoverage` in both directions (no extrapolation, M2-C3), and sources wholly outside it are reported. Extending to the whole epoch is a separate explicit decision (`extendProposalToEpoch`), recorded as `manual` provenance with a note saying so. Before building, `accept` re-checks the report's plan (source → group/epoch placements, epoch membership) and probed facts (revision tokens, format/envelope revisions) against the current episode and registrations; any change is `analysisStale`, never applied. Prior-map dependencies are verified before an undecided epoch carries a numeric correction, anchors or explicit rejection. An explicitly accepted acoustic proposal carries forward only when its current analysis key (including peer revisions), current proposal and supported segment still match the accepted evidence; a new abstention or changed evidence drops it. Unaccepted proposals cannot override new abstentions. The map revision persists a dependency digest (placements, revision tokens, format) and accepted-proposal analysis keys in its recipe; `activate` and every render re-verify the map dependencies. Acceptance is a serialized transaction per episode: a pipeline refuses an acceptance built on a document snapshot other than the one it last activated (`staleSnapshot`), and only the latest acceptance issued on that snapshot can activate (`supersededAcceptance`). A proposal measured against another reference or source revision is refused. A prior `clockApproved` epoch is refused, never carried forward, and nothing in the module can construct `ClockApproval` or `.clockApproved` (`ForbiddenAPITests`, `AcceptanceTests`). |
| Render | `AlignmentPipeline.renderAlignedAssets` | For the accepted, active and applicable map whose dependencies still verify (`mapStale` otherwise), streams `WWRender` output for every same-group channel, segment by segment, into `DerivedAssetStore` (app cache only), with recipe, renderer and asset versions in the key. `activate` publishes the accepted map's **content identity** (a digest of the canonical encoded map version: map, inputs and dependency record) through the coordinator, and every aligned segment names it as an upstream in its key and records it in its header, so two different maps with the same revision number never share or adopt each other's audio; a render refuses unless the coordinator is publishing that exact content (`acceptedMapContentNotActive`). The output hull covers only the placed (covered) spans, so frames outside a partial proposal are never mapped. Every group renders at one episode-wide output rate. That rate is decided by the WW-050 `OutputSettingsPolicy` over the probed `FormatInterpretation` of every renderable source: by default 48 kHz, or `matchSources` when configured. The decision and its reasons are in the report, and the policy version and rate are in each segment's recipe name. Cached assets stay binary32; the policy's sample format applies at M4 export. Each segment re-checks the accepted revision and content identity, cancellation and shutdown before it starts, and the coordinator's commit-time currency check discards late results. Each whole group render is registered as tracked work before any cursor opens; `AlignmentPipeline.shutdown()` refuses new renders, cancels the running ones and the coordinator, and returns only after every render (and so every gateway cursor) has finished. Export stays blocked (M4). |
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
- Multi-recorder analyses retain only decimated 20 s peer excerpts, scoped to that run. Their aggregate
  footprint is reserved in each admission and capped at one eighth of the configured memory budget;
  larger cohorts refuse with a typed memory-budget outcome rather than decoding peers quadratically.
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

Package suites (`swift test --filter "WWAlignPipelineTests|ForbiddenAPITests"`, 70 pipeline tests in 15 suites; synthetic only):

- **End to end:** decode → propose → accept → activate → render → map change invalidates the renders.
  Rendering the same revision again reuses every segment and opens nothing.
- **Abstention** (7 cases): silent, unrelated (weak), periodic, echo (ambiguous), offset step
  (discontinuous), short reference (disconnected) and an unreachable search range (insufficient coverage).
  Each resolves to its WW-014 state and remedies, with full evidence stored.
- **Cycle/restart/gap:** consistent and conflicting 3-recorder cycles, a weak peer, a failed third
  probe that blocks its peers, a failed sibling epoch that does not block the only target recorder's
  healthy epoch, linear reader opens for three targets, a declared restart plus an
  in-recording step, and an internal gap with no supported inverse.
- **Eligibility:** OFF, unauthorized, unregistered and unlocated sources are planned out with typed
  reasons and never reach the decoder. With every source OFF, the whole run is metadata only (zero opens
  through the recording gateway). Turning a source OFF before rendering skips its channels without opening
  it. A source rewritten since registration is refused at the probe, and a source changed after analysis
  drops its proposal.
- **Acceptance:** versioned revisions; numeric entry; anchors; reject → U8; undecided epochs; refusal of a
  stale proposal, of accepting or extending without a proposal, and of a `clockApproved` prior; `activate` refusing a revision the document does not accept;
  a source-scan check against forging approval.
- **Concurrency:** deterministic late analysis and late render (the map changes while the job is held at
  commit) with negative controls that publish; cancel mid-decode; cancelling the caller at commit;
  shutdown during render; bounded admissions and readers; a shared gate; over-budget refusal.
- **Map currency** (`MapCurrencyTests`, `GuardTests`, `ConcurrencyTests`; review findings F1–F5 on #210):
  - F1: two accepts from one snapshot: the first is superseded, the second activates; a second pipeline
    activating a different map under the same revision number re-renders everything (no segment of the first
    map is adopted, every key differs and names only the new map's identity as upstream); a render under
    a map whose identity is not the published one is refused before opening anything; every segment header
    records the map content digest; `activate` refuses an acceptance carrying another version's identity or
    another result (positive control: the genuine one activates).
  - F2: `shutdown()` called while the first group render is held before its first commit returns only after
    every cursor is closed; negative control: with tracking disabled (DEBUG hook) it returns while a cursor
    is still open. `shutdown()` also cancels a render still queued for admission: it returns while the gate
    stays held, and nothing opens.
  - F3: moving a source to another epoch of the same group after analysis makes `accept` refuse
    (`analysisStale`); after acceptance, render refuses (`mapStale([.sourceMoved])`); a source-revision change
    after acceptance makes `activate` refuse and after activation makes render refuse; a map revision without
    a dependency record is never rendered.
  - F4: a centred 10-minute proposal on a 75-minute source places only its interval; frames outside are
    `outsideCoverage` forward and inverse; the render hull is the interval's; the proposal is clipped to the
    source; a source wholly outside is reported; extending to the epoch is explicit and `manual`.
  - F5: the accepted-map identity key carries the registered revision of every source the map uses (its
    placements, including the timeline reference's, and its inputs), so a change to *any* of them makes the
    identity stale in the coordinator, which cascades to every aligned segment, including other sources'.
    `ConcurrencyTests` holds the target group's first segment commit, changes the reference source's
    revision, and asserts that no target segment publishes (`discardedStale` with `upstreamChanged`, group
    failure `acceptedMapChanged`, identity slot stale with `sourceChanged(ref)`, re-render refused as
    `mapStale`); negative control: an identity without source revisions (DEBUG hook) lets those stale
    segments publish. `GuardTests` checks the per-segment check stops on a reference-only change and that
    placements and inputs are each keyed (and must be registered) independently.
  - `GuardTests` adds the per-segment content-identity check (same revision number, different content).
- **Output settings:** mixed 48 / 44.1 kHz sources render at the policy's 48 kHz, and the resampled 44.1 kHz
  target lands on the timeline truth (relative error < 0.02). All-44.1 kHz sources render at 48 kHz by
  default and at 44.1 kHz under `matchSources`. When nothing is renderable there is no decision and no
  open.
- **Guards** (`GuardTests`): direct tests for the defence-in-depth checks the end-to-end suites cannot reach.
  These are `admitted` for registered but ineligible sources; a probe refusing another format or envelope
  revision; `build` refusing a proposal measured on another source revision; analysis decode stopping within
  one chunk of the needed range; refusal of an inapplicable map before any open; and the per-segment
  map-revision, shutdown and cancellation checks.
- **Units:** `ResourceGate` (cap, budget, FIFO, refusal, cancelled waiter), `TrackedWork` (refuses and never
  starts work after close), `boundedMap`, configuration
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
it waits while the 1-minute load is ≥ 24; 420 s per run). Round 1 (M01–M31) ran on 2026-10-06 at the
policy-integration head; every mutation was rerun later on 2026-10-06 after the review fixes (F1–F4), and M32–M62
were added for those fixes. For F5, M63–M66 were added and the identity-related M39, M48–M52, M60 and M61 were
rerun on the F5 head (M39 and M48 retargeted at the moved activate checks). **65 of 66 killed; M07 is equivalent** (subsumed by the identity check; M61, which
removes both checks, is killed). The round-1 survivors (M04, M06–M09, M20, M21, M25, M27) are killed by
`GuardTests`. The round-2 survivors (M48, M58, M59, M60) and F5 survivors (M64, M65: the fixtures' placements and inputs name the same sources) are killed by tests added for them. The early
`noCurrentProposal` prefilter that the old M19 removed duplicated the check where the decision is applied, so it
was deleted; M19 and M62 now check that check.

| ID | Mutation | Result | Killed by |
|---|---|---|---|
| M01 | OFF availability ignored | killed (4) | Each ineligible source is planned out, never opened, and shown as a Setup block; Turning a source OFF before rendering skips its channels without opening it; With every source OFF the whole run is metadata only; `admitted` never lends a location or revision for an ineligible source, even one that is registered |
| M02 | consent ignored | killed (4) | Each ineligible source is planned out, never opened, and shown as a Setup block; Turning a source OFF before rendering skips its channels without opening it; With nothing renderable there is no decision and no output rate, and nothing is opened; `admitted` never lends a location or revision for an ineligible source, even one that is registered |
| M03 | registration ignored | killed (2) | Each ineligible source is planned out, never opened, and shown as a Setup block; `admitted` never lends a location or revision for an ineligible source, even one that is registered |
| M04 | admitted skips check | killed (1) | `admitted` never lends a location or revision for an ineligible source, even one that is registered |
| M05 | verify token skipped | killed (1) | A source rewritten since registration is refused at the probe and blocks its epoch until re-registered |
| M06 | verify format revision skipped | killed (1) | A decoder interpretation from another format or envelope revision is refused, whatever the revision token |
| M07 | render map-currency check removed | equivalent | Subsumed: a revision change also takes the identity slot out of `.ready`, so the identity check (M51) stops the render first. M61 removes both checks and is killed |
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
| M19 | accept without proposal reports another refusal | killed (1) | abstains |
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
| M32 | F4 coverage lower clamp removed | killed (1) | A proposal reaching past either end of the source is clipped to the source's frames |
| M33 | F4 coverage upper clamp removed | killed (2) | A proposal reaching past either end of the source is clipped to the source's frames; A source with no frame inside its epoch's proposal is left unplaced and reported, never stretched |
| M34 | F4 accept extends proposal to epoch | killed (3) | A centred 10-minute proposal on a 75-minute source maps only its interval; the rest stays outsideCoverage both ways; A proposal reaching past either end of the source is clipped to the source's frames; A source with no frame inside its epoch's proposal is left unplaced and reported, never stretched |
| M35 | F4 placement ignores coverage | killed (8) | A centred 10-minute proposal on a 75-minute source maps only its interval; the rest stays outsideCoverage both ways; A persisted clock approval is shown refused, never carried forward, and replaced only by an explicit decision; A proposal reaching past either end of the source is clipped to the source's frames; A source with no frame inside its epoch's proposal is left unplaced and reported, never stretched; A synthetic episode is proposed, accepted, rendered, re-timed and re-rendered; nothing on the main thread; Every decision yields only timelineReference or manual provenance, versioned and derived from the prior revision; Undecided epoch carries its current proposal unaccepted (U3); an explicit reject returns it to U8 and stays rejected; `build` refuses or withholds a proposal measured on another revision of either source, even if handed it directly |
| M36 | F4 extension not recorded in note | killed (1) | Extending a proposal over the whole epoch is an explicit manual decision that says so |
| M37 | F4 hull uses whole occurrence | killed (2) | A centred 10-minute proposal on a 75-minute source maps only its interval; the rest stays outsideCoverage both ways; A synthetic episode is proposed, accepted, rendered, re-timed and re-rendered; nothing on the main thread |
| M38 | F3 accept ignores analysis changes | killed (2) | A source that changes after analysis drops its proposal: shown pending, never accepted; Moving a source to another epoch of its group after analysis makes accept refuse the stale plan |
| M39 | F3 activate ignores dependency verify | killed (1) | A source revision change after acceptance refuses activation and rendering of the map |
| M40 | F3 render ignores dependency verify | killed (3) | A map revision without this module's dependency record is never rendered; A source revision change after activation refuses rendering before opening anything; Moving a source to another epoch of its group after acceptance makes render refuse before opening anything |
| M41 | F3 missing dependency record tolerated | killed (1) | A map revision without this module's dependency record is never rendered |
| M42 | F3 dependency digest not compared | killed (2) | A source revision change after acceptance refuses activation and rendering of the map; A source revision change after activation refuses rendering before opening anything |
| M43 | F3 verify ignores placements | killed (1) | Moving a source to another epoch of its group after acceptance makes render refuse before opening anything |
| M44 | F3 placementChanges ignores epoch | killed (1) | Moving a source to another epoch of its group after acceptance makes render refuse before opening anything |
| M45 | F3 analysisChanges ignores epoch | killed (1) | Moving a source to another epoch of its group after analysis makes accept refuse the stale plan |
| M46 | F3 analysisChanges epoch membership ignored | killed (1) | Moving a source to another epoch of its group after analysis makes accept refuse the stale plan |
| M47 | F3 analysisChanges ignores revision token | killed (1) | A source that changes after analysis drops its proposal: shown pending, never accepted |
| M48 | F1 activate skips identity check | killed (1) | activate refuses an acceptance whose identity or result does not match the document's map version |
| M49 | F1 render skips identity-active check | killed (1) | Two accepts from one snapshot: only the latest activates, and the stale snapshot is refused afterwards |
| M50 | F1 segment key omits identity | killed (3) | A change to the reference source while a target segment commits discards every target segment; an identity without source revisions (negative control) would publish them; A different map under the same revision number never adopts the first map's aligned assets; Two accepts from one snapshot: only the latest activates, and the stale snapshot is refused afterwards |
| M51 | F1 checkCurrent skips identity | killed (2) | Between segments a render stops when any source the map uses changes, not only its own; Between segments a render stops when the active map content is not its identity, even under the same revision number |
| M52 | F1 identity is revision number only | killed (4) | A different map under the same revision number never adopts the first map's aligned assets; Between segments a render stops when the active map content is not its identity, even under the same revision number; Two accepts from one snapshot: only the latest activates, and the stale snapshot is refused afterwards; activate refuses an acceptance whose identity or result does not match the document's map version |
| M53 | F1 ledger issue accepts stale snapshot | killed (2) | A persisted clock approval is shown refused, never carried forward, and replaced only by an explicit decision; Two accepts from one snapshot: only the latest activates, and the stale snapshot is refused afterwards |
| M54 | F1 ledger activate accepts stale snapshot | killed (1) | Two accepts from one snapshot: only the latest activates, and the stale snapshot is refused afterwards |
| M55 | F1 ledger superseded check removed | killed (1) | Two accepts from one snapshot: only the latest activates, and the stale snapshot is refused afterwards |
| M56 | F2 render not tracked | killed (1) | shutdown() returns only once every render reader is closed; untracked renders (negative control) let it return with a reader open |
| M57 | F2 shutdown does not await renders | killed (1) | shutdown() returns only once every render reader is closed; untracked renders (negative control) let it return with a reader open |
| M58 | F2 shutdown does not cancel renders | killed (1) | shutdown() cancels a render still waiting for admission: it returns without the gate ever being released |
| M59 | F2 tracked work not refused after close | killed (1) | run returns the result and deregisters; after close it refuses and never starts the operation |
| M60 | F1 segment header omits map digest | killed (1) | A different map under the same revision number never adopts the first map's aligned assets |
| M61 | checkCurrent both map checks removed | killed (3) | Between segments a render stops when any source the map uses changes, not only its own; Between segments a render stops when the accepted map is no longer its revision; Between segments a render stops when the active map content is not its identity, even under the same revision number |
| M62 | extend without proposal reports another refusal | killed (1) | abstains |
| M63 | F5 identity key omits source revisions | killed (2) | A change to the reference source while a target segment commits discards every target segment; an identity without source revisions (negative control) would publish them; Between segments a render stops when any source the map uses changes, not only its own |
| M64 | F5 used sources omit placements | killed (1) | The identity is keyed on the map's placements and its inputs, each independently |
| M65 | F5 used sources omit map inputs | killed (1) | The identity is keyed on the map's placements and its inputs, each independently |
| M66 | F5 identity token is not the registered revision | killed (26) | Every test that renders an accepted map (the coordinator sees the published identity's token as a stale source revision), e.g. A synthetic episode is proposed, accepted, rendered, re-timed and re-rendered; nothing on the main thread; A change to the reference source while a target segment commits discards every target segment; an identity without source revisions (negative control) would publish them; shutdown() returns only once every render reader is closed; untracked renders (negative control) let it return with a reader open |

## Multi-recorder follow-up (WW-021)

`CycleTests` uses deterministic 3-recorder scenes and a declared two-epoch restart. Each analysis
request includes the reported target and the other eligible epochs; the frozen estimator measures
peer-to-peer windows against the reference-relative fits. The analysis asset is revision 2 and its
record schema is version 2: each record now persists `cycleTriangles`, the maximum disagreement
in milliseconds (nil when unavailable), and the estimator's sorted flags. Its key includes every
peer source revision and the cohort's epoch identities. A conflicting cycle abstains both affected
epochs (`cycleInconsistent`), with numeric-entry/anchor remedies; no target is silently selected.
An unmeasurable cross-group cycle abstains as `insufficientCoverage`. Declared restarts retain
`restartedEpoch`; an additional step inside an epoch abstains as `discontinuous` rather than
bridging it. An internal `coverageGap` demotes any whole-span proposal to a discontinuous,
unsupported epoch until a boundary or anchors are supplied; the resulting map has no inverse
there. Two-recorder analyses keep their original single-target request and key.

The strict cooperative-pool targeted pass (`WWAlignPipelineTests|ForbiddenAPITests`) passed
70 pipeline tests and 12 forbidden-API tests. The serialized `WW_PIPELINE_HEAVY_TESTS=1`
three-recorder pass passed: resident peak 340 MiB (<1 GiB), sampled footprint 300 MiB
(<768 MiB), and gate peak 425 MiB of the 512 MiB budget; both target proposals published.

Review fixes on 2026-10-07: the strict targeted pass passed 74 selected tests in 15 suites.
The serialized heavy pass passed with 11 reader opens (6 probes, 2 reference reads, 2
long-form targets, 1 one-time peer excerpt), down from 12 before sharing; 373,194,752
distinct source frames were reached, both targets proposed, resident peak 339 MiB, sampled
physical footprint 300 MiB, and peak gate reservation 426 MiB / 512 MiB. The reservation
includes the bounded, decimated peer cache.

| Mutation (applied alone, then restored) | Targeted outcome |
|---|---|
| M67: omit peer tracks from the estimator request | killed: the conflicting-cycle test failed with 10 issues, including missing cycle evidence and wrong abstentions |
| M68: discard the estimator's `restartedEpoch` flag before persistence | killed: the restart test failed with 2 missing-flag issues |
| M69: skip checking the expected recorder cohort before analysis | killed: failed-third-probe test reported 6 issues (a two-recorder proposal published) |
| M70: carry forward prior mappings regardless of current analysis or prior dependency verification | killed: cycle-abstention test reported 2 issues (stale proposal retained) |
| M71: omit the run-local peer excerpt cache | killed: three-target reader-open test reported 4 issues (quadratic peer reads) |
| M72: remove accepted acoustic proposal carry-forward | killed: 3 issues in three-recorder and two-recorder sequential-acceptance tests (first epoch reverted to an unaccepted proposal) |
| M73: restore target-epoch counting in the missing-peer guard | killed: 4 issues in the two-recorder failed-sibling test (healthy epoch incorrectly blocked) |

## Known limits and risks

- The proposal for an epoch is one affine segment over the analysed interval only; frames outside it are
  `outsideCoverage` (not rendered). Covering the whole epoch needs the explicit `extendProposalToEpoch`
  decision (manual provenance). Every source in an epoch is placed at group-clock 0.
- Each target epoch is estimated with all other eligible target epochs against the same reference. The
  reported target keeps its configured excerpt; each peer uses a centred 20 s excerpt to bound memory and
  supply at least five common windows for the frozen cycle check. An unavailable planned recorder blocks
  the dependent cycle analyses. The peer excerpts are shared by source revision within a run; the first
  target's decoded buffer supplies its own peer excerpt when the decimator phases align. Missing-peer
  blocking requires at least three distinct planned recorder groups: one recorder's failed restart epoch
  does not prevent its healthy epoch from being analysed against the reference. The frozen cursor
  still reads every long target and reference from frame zero, so the heavy pass needs 11 opens versus the
  original two-recorder 10. Cycles cannot establish clock truth or
  detect acoustic propagation delays common to every pair. A target with no measurable cross-group
  triangle is unsupported, not silently promoted. Restart flags reflect *declared* epochs, not a proven
  device reset; a step inside an epoch abstains until the person declares a boundary or places anchors.
- Analysis decodes sequentially from frame 0, with no seek. For a centred 600 s excerpt of a 75-minute
  file, that decodes about 57 % of the reference and target.
- Estimator CPU runs on the cooperative pool, limited only by the gate's permits.
- Sources without probed facts are omitted from maps, and unsupported (U7/U8) epochs are not rendered.
  Epochs carrying an accepted acoustic proposal (U3) are rendered.
- Accepting and activating are two steps. A pipeline instance only remembers what it activated: after a
  relaunch (fresh pipeline), a saved accepted map renders only after it is accepted and activated again;
  there is no public restore path yet. An out-of-band edit to the episode's alignment (another writer)
  makes this pipeline refuse further acceptances (`staleSnapshot`); a new pipeline instance is needed.
- The memory bound is measured for analysis. The aligned-asset render was exercised on short fixtures
  only; a full 75-minute render (debug ≈ 0.1 s per channel-second) is unmeasured.
- The pipeline streams through the WWDecode pull cursor, `SourceDecoder.withDecodingCursor` /
  `DecodingCursor`. WWRender's provider pulls samples, while the frozen decoder pushes them into a
  synchronous sink, so a bridge would either buffer whole sources or block a cooperative thread. The
  cursor merged to main in #212 (`m2-freeze-decode-2`), and main was merged into this branch, so WWDecode
  here is identical to main and the freeze pin passes. Main's cursor does its synchronous reads on a
  private serial queue. The mid-decode cancellation test therefore cancels the epoch's coordinator slot
  from inside the read, waiting on that non-cooperative queue for the cancel to land. Negative control: if
  the cancel is a no-op, the test fails.
- Merging main brought a bare `contentsOf` token into `ForbiddenAPITests.forbidden`. The WWDerived and
  WWAlignPipeline scans mask only two forms: in-memory `.append(contentsOf:`, and the store's own
  `files.contentsOfDirectory(` listing, which is masked in `DerivedAssetStore.swift` alone.
  `String(contentsOf:)` and every other `contentsOf` form stay flagged. Four scanner mutations were
  checked and all four were killed: mask removed, mask applied to every `contentsOf`, store listing allowed
  everywhere, and store listing not allowed in the store.
