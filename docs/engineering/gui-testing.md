# GUI test pipeline

Use the [macOS VM hosts](ui-test-vm-hosts.md), normally `ww-ui-1` or `ww-ui-2`.
The host guide owns readiness checks and physical-host exceptions. The user's
desktop and Mac mini are not fallback test hosts.

## Choose the test scope

The PoC gate covers working app features, not broad accessibility qualification.
The shared `WaveWranglerUITests` scheme defaults to the **PoC** test plan.
All 157 current UI tests remain represented in at least one plan; overlapping
plans deliberately exercise some workflows both with and without audits.

| Plan | Scope | Runner selection |
| --- | --- | --- |
| PoC | 17 Add Audio/timeline Finder-drop, linear clip fades and graphical/numeric automation editing/Undo, import/playback, integrated workspace, docked/detached mixer, transcript review/Undo, cut review, saved episode views, selection toolbar, playhead zoom, scroll, reopen/save, damaged-file refusal, and empty-workspace recovery tests | `scripts/test.sh --ui` |
| Regression | 134 functional tests, including axis-locked automation handles, fade duration/end-time, explicit automation conflict replacement and detached-review production, sequential multi-file timeline drops and reuse, folder refusal, the mixer/Apple editor, detached transcript review/filter/cut Undo workflow, timing-reference selection, alignment reset with Undo/Redo, source-time Solo, paired manual anchors and subsequent drags, timeline fitting/following/cycle creation, keyboard shortcuts, source onboarding/file drops/group drags, source grants, relink, cancellation, persistence, conflicts, and recovery | `scripts/test.sh --ui-profile=regression` |
| Accessibility | 73 audit-bearing, appearance/200%-layout, native AX geometry, keyboard-focus, and VoiceOver tests | `scripts/test.sh --ui-profile=accessibility` |
| Performance | 5 responsiveness measurements, separate from feature correctness | `scripts/test.sh --ui-profile=performance` |

These commands launch on their **current host**: use them only on an approved,
leased test host, not the development desktop. For staged VM Products, use the
build/run pipeline below instead.

Feature tests retain their functional and safety assertions. Their embedded
accessibility audits log `ACCESSIBILITY DEFERRED` unless the Accessibility plan
sets `WW_UI_ACCESSIBILITY=1`. Dedicated audit/VoiceOver cases explicitly skip
without that admission flag. Deferral is **not** a passing accessibility result:
thresholds, waivers, labels, native controls, and dedicated tests are retained for
the post-PoC accessibility pass. Full Keyboard Access and VoiceOver still require
their documented guest configuration; selecting a plan does not enable them.
The real-speech/model test remains separately opt-in within Regression.

`--ui -only-testing:WaveWranglerUITests/Class/test` automatically uses Regression,
so selectors outside PoC do not silently intersect with the smaller default plan.
Use an explicit `--ui-profile=accessibility` for focused audit/appearance tests,
or `--ui-profile=performance` for timings. Explicit profile selection wins; Xcode
intersects `-only-testing` with that plan's selection. Check the result's actual
test identities and nonzero count, not just the command's exit status.

`python3 scripts/test-ui-plans.py` checks selector existence, complete plan
coverage, environment admission, the scheme default, and CLI routing without
launching apps. Its static checks also run before `scripts/test.sh`.

### Sustained production playback qualification

The hosted test below is opt-in with `WW_PRODUCTION_TIMING_TESTS=1` in the
test runner's environment. Build the `WaveWranglerHostedTests` scheme with
isolated DerivedData (for example, `.build/DerivedData-playback-reliability`)
and two workers, then stage and run on a ready, leased VM using the pipeline
below. Do not execute hosted audio tests on the development desktop.
Swift Testing method selectors require the parentheses:

```text
-only-testing:WaveWranglerHostedTests/SustainedProductionPlaybackHostedTests/adaptiveProductionSurvivesLiveInsertEditingSavingAndTranscriptLayout()
```

The test plays 32 seconds of real production audio from two authorized,
generated 48-second originals. Its accepted map has one smooth adaptive segment
over the first 40 seconds and 4,096 short segments in the final eight seconds:
recording-sized metadata does not turn the played interval into thousands of
tiny stretch operations. The run starts with cold adaptive audio tiles and
crosses at least seven five-second tiles using the configured 250 ms
post-production scheduling target and 200 ms refill low watermark.

Two speaker inserts and one master insert use native Apple Lowpass units.
A generic editor remains active with normal observation timing while explicit
controller edits alternate with native parameter edits that observation must
capture. Main-actor transcript layout performs actual CPU work with suspensions,
and real saves occur around program seconds 12 and 25. Acceptance includes
exact program-end completion without an error, live mute/unmute DSP meters,
the same processing instance, verified save/reload, post-playback Undo/Redo and
parameter recall, unchanged accepted timing, and byte-identical synthetic
originals. Counters require editing, capture, and layout after second 21.
The synthetic alignment window must finish attaching and loading its initial
waveforms before transport starts; initial view setup is not playback load.
The completion deadline is 60 seconds beyond the selected playback duration,
separate from setup waits;
there is no per-cold-window one-second performance gate.

Record the bounded numeric `SUSTAINED_PRODUCTION` and `PRODUCTION_RESERVE`
summaries and actual executed test identities/counts. Repeat with two or three fresh fixtures for qualification
evidence. Retain the `FlattenedPlaybackHostedTests` negative controls for
intentional queue starvation, refusal of externally changed sources, and
stop/stale-producer invalidation. Existing deterministic queue and control
horizon tests remain responsible for their bounds.

These are VM functional regression results, not supported physical-hardware
performance qualification.

#### Full 15-minute episode soak

For a self-contained synthetic stress run, enable
`WW_SYNTHETIC_EPISODE_SOAK_TESTS=1` and select
`SustainedProductionPlaybackHostedTests/fifteenMinuteSyntheticEpisodeWithStockCompressionEQEditingAndSaves()`.
This generates two distinct 920-second, 8 kHz mono originals using the existing
fixture generator and processes them at the production 48 kHz rate. It does
not download speech or inspect user media, and it is not equivalent to the
external-speech qualification below. It runs the same 900-second episode,
six stock inserts, live edits, periodic verified saves, cold adaptive tiles,
layout work, and persistence/Undo/source-integrity checks.

Minute progress includes cumulative minimum buffer reserve, maximum render,
processor-submission wait, source wait, and refill wake delay. Resource summaries
report cumulative CPU seconds and process-lifetime peak RSS in MiB for the
application/test-host process, not out-of-process Audio Units or the entire VM.
Use the start/end readings to separate fixture setup from playback CPU.
Two simultaneous four-vCPU guest runs stay within the eight-vCPU budget, but
intentionally include shared-host contention; label that load in the evidence.

For the persisted-transcript/cut variant, enable `WW_TRANSCRIPT_CUT_SOAK_TESTS=1`
and select
`SustainedProductionPlaybackHostedTests/fifteenMinuteTranscribedSyntheticEpisodeWithRandomCuts()`.
It saves 4,500 synthetic timed words and detects 100 filler suggestions per
Primary across the original 900-second window. Using `WW_TRANSCRIPT_CUT_SEED`
(an unsigned integer, default `7`), it samples exactly 50 suggestions per track
without replacement and applies the ordinary review cut action. The 100
nonoverlapping 200 ms removals ripple across both tracks, leaving 50 unapplied
suggestions per track and **880 seconds of actual edited playback**, not 900.
The real alignment window receives the persisted cleanup model and renders its
transcripts and overlays. The original 40,000-word layout workload is retained,
with additional layouts of both cut-projected transcripts. All six effects,
live edits, observation, saves, cold tiles, Undo/Redo, and immutable-source checks
remain enabled. Setup verifies witnessed transcript validity, proposal-to-cut
bindings, per-track counts, removal geometry, shortened episode bounds, and
saved-state round trips before playback. Logs include the seed and selected
aligned frame positions. Compare CPU per played second, not only total CPU,
against the uncut 900-second baseline. Edit and layout loops are cadence-driven,
so retain their completed operation counts: additional window rendering can
reduce those counts while increasing total CPU. This is a combined stress
comparison, not an isolated measurement of per-cut rendering cost. A
`PRODUCTION_RESERVE` summary alone is not a pass; require the final test result
after persistence, Undo/Redo, and recall checks, and preserve post-playback
window/graphics stalls separately from audio underruns.

#### Controlled transcript UI comparison

Enable `WW_TRANSCRIPT_UI_COMPARISON_TESTS=1` and select
`SustainedProductionPlaybackHostedTests/controlledTranscriptUIComparison(_:)`
on a ready, leased VM. Its three serialized arguments are `none`, `transcript`,
and `cuts`: no persisted transcript, 4,500 persisted words/100 suggestions per
track without cuts, and the same transcript fixture with 50 randomly chosen
cuts applied per track. Each case creates fresh synthetic originals, six stock
inserts and cold adaptive tiles, shows the full episode viewport, and plays
exactly 60 seconds. Cut cases contain real removed audio; they are not
sample-identical to the uncut cases. Compare before/after within each case.

The comparison excludes the separate 40,000-word/layout-burst workload. It
requires six explicit and six normally observed native parameter edits on the
same program-time schedule, two verified saves at seconds 15 and 45, live
mute/unmute, positive nonfinal reserve, full completion, Undo/Redo, parameter
recall, unchanged cleanup/timing, and byte-identical originals. Keep operation
counts: normal editor polling/capture is still cadence-driven.

`TRANSCRIPT_UI_RESPONSIVENESS` reports main-actor wakeup delay beyond a 20 ms
sleep (p95 and maximum, at most 10,000 samples) and the longest completed
parameter operation. This is scheduling/operation latency, not event-to-photon
or audible-control latency. CPU and peak RSS retain the app/test-host-only
meaning above. Use the same guest, build configuration, worker count, seed,
viewport, and shared-host load for before/after comparisons; repeated runs are
needed before treating small timing differences as significant. Preserve
setup failures and graphics stalls rather than including incomplete cases
in performance averages. Allow 300 seconds per argument and a 15-minute lease.
The fixture awaits editor-state disposal before closing the document and
deleting synthetic files, including on failure. Disposal happens after all
save/recall assertions and never substitutes for them. A failed processor can
no longer leave asynchronous document capture racing fixture deletion or
presenting a teardown error dialog over the next argument.

A development comparison on one four-vCPU/16-GiB VM (Debug, one worker, seed 7)
completed all three cases twice per build. The repeat pair, without concurrent
local builds, measured:

| Case | App CPU-seconds/program-second, before / after | Main-actor p95 excess wakeup delay, before / after |
|---|---|---|
| No transcript | 0.658 / 0.616 | 14.1 / 13.1 ms |
| Persisted transcripts | 0.885 / 0.675 | 23.3 / 14.2 ms |
| Transcripts with applied cuts | 1.338 / 1.287 | 200.3 / 136.1 ms |

The baseline retained diagnostic instrumentation but used the previous global
cache invalidation and inline transcript UI. Every case completed the fixed
12 edits and two saves, plus post-playback checks; cadence-driven captures are
not fixed (the repeat cut case completed 204 before and 251 after). This is
limited dirty-tree VM evidence, not an exact-commit or physical-device
qualification. Long tails remain: the optimized repeat cut case's maximum
main-actor delay was 1.618 s and longest parameter operation was 2.820 s.
Positive reserve does not diagnose the original user's underrun or resolve the
separately observed graphics-IPC stall.

The optimized full seed-7 cut soak also completed 880 program seconds with
325 parameter edits, 3,247 captures, 15 verified saves, 180 adaptive tiles,
5,928 injected layout bursts, and all final persistence/Undo/Redo/recall checks.
Minimum nonfinal reserve was 5,813 frames (121.1 ms); the longest DSP render was
118.54 ms. This confirms completion under that stress workload, not elimination
of long rendering outliers or an operation-matched speedup.

**Projection-stall follow-up.** A warmed 50 Hz cut-playback profile identified
repeated presentation-projection construction and per-cut Observation reads:
623 inclusive main-thread samples passed through `presentationTimeline` out of
2,240 main-thread samples. Nested stack counts are not additive CPU percentages.
The unexpanded path now avoids scanning saved cuts or observing unrelated
document publications; render/filter passes reuse one immutable projection.
Expanded-cut changes remain observed, and pointer/drag handlers read live
geometry rather than a render-time snapshot.

A subsequent unprofiled comparison reused the preserved pre-fix build and the
final fixed build on the same warmed VM, with no concurrent build or profiler:

| Case | App CPU-seconds/program-second, before / after | Main-actor p95 delay, before / after | Longest control completion, before / after |
|---|---|---|---|
| No transcript | 0.712 / 0.507 | 13.9 / 9.5 ms | 0.285 / 0.194 s |
| Persisted transcripts | 0.750 / 0.747 | 14.7 / 14.0 ms | 0.290 / 0.317 s |
| Transcripts with applied cuts | 1.256 / 1.368 | 98.7 / 88.2 ms | 2.063 / 1.213 s |

Both builds passed all three cases and final checks, with 12 scheduled edits
and two verified saves per case. Cut captures were 275 before and 296 after.
Cut maximum main-actor delay increased from 1.485 to 1.679 s; minimum reserve
remained positive at 9,113 / 8,719 frames. An earlier unprofiled fixed run also
passed all cases, with cut p95 delay 76.2 ms and longest control 1.104 s.
These bounded runs support removal of redundant work and improved observed
control responsiveness, not reduced total CPU or elimination of long stalls.
The final focused run passed 75 tests across six suites, including unexpanded
and expanded Observation dependencies, strict projected viewport overlap,
collapsed intervals, source identity, and failed-controller fixture disposal.

Preserve the unsuccessful diagnostics separately. A cold overloaded run
underran, then blocked in an AppKit error dialog during fixture teardown;
awaited disposal now has a focused regression. A sampled fixed run still
underran in its cut case (332 ms append gap and zero reserve). Sampling may
perturb scheduling, but its causal role is unproven. A later guest-disk-full
attempt is invalid benchmark evidence; archived task-owned results allowed
the matched comparison and final regression run above to complete normally.
The separate preserved graphics hang blocked in Core Animation IPC and
paravirtual GPU cleanup. It was not reproduced or fixed by this change.
Neither passing comparisons nor positive reserve diagnose the original user's
underrun. At this checkpoint, no new full-length soak had completed after the
projection fix; the 880-second result above qualifies the preceding cache
optimization. The later native checker-control qualification is recorded below.

**Post-merge graphics investigation.** The buffered-rendering, transcript
benchmark, cache/projection, and qualification changes were published and
reconciled with live playback cycles in `dd55dedb`. Focused merged regressions
reported 140 passes, two skips, and zero failures. A package run separately
retained the unchanged supplemental-clip fixture failure that requests playback
outside Episode Start/End; excluding that fixture, 58 mixer tests and six
insert-rack tests passed.

Two warmed seed-23 retries on VM2 alone failed before the original graphics
hang's post-playback phase, after 213.6 and 338.5 wall seconds. Both recorded real
underruns without an active profiler, preceded by Core Audio overload messages.
The second recorded five queued raw windows, a 0.135 ms maximum source wait, a
201.4 ms append gap, and an enqueue operation still active after 198.7 ms. Guest memory
counters collected afterward showed no compression or swapping; these
observations do not identify the stalled operation or diagnose the original
user's failure.

Shorter three-case retries exposed another test-harness teardown race. A
stall-triggered sample showed `ShowDocument.close()` presenting a windowless
AppKit error dialog, while the guest WindowServer sample showed ordinary event
waits, not the original paravirtual-GPU cleanup stack. `exercise` had closed its
last window in a synchronous defer before the outer runner awaited disposal of
the failed mixer. The document now retains that window until awaited mixer
disposal and document close; the failed-controller regression also opens a real
window and verifies it closes before synthetic-file cleanup completes.

With that test-only ordering correction and phase breadcrumbs, the focused
failure-disposal regression passed and all three seed-23 comparison cases
completed their final save, Undo/Redo, recall, original-byte integrity, and
disposal checks. Minimum rendered reserves were 8,581 / 8,605 / 8,627 frames for
no transcript / transcript / applied cuts. This is bounded dirty-tree evidence,
not a full-soak pass or matched performance comparison: 60 program seconds took
90.9 / 96.3 / 94.9 wall seconds, and the no-transcript probe recorded a 30.8 s
main-actor delay. The original Core Animation/paravirtual-GPU hang remains
unreproduced and unresolved; no production graphics workaround was applied.

Two separately approved native-GPU diagnostic attempts on macOS 27.2
(`26B123`, versus guest macOS 27.0 `26A428`) failed before reaching that graphics
phase. The first failed after 29.632 test seconds. Both reported replacement of
the live processor after one explicit parameter edit, without a playback or
editing error; neither triggered the stall watchdog's stack capture. The second
attempt traced revision 102 changing to 103 through
`EpisodeMixerController.load` and its serialized `prepare` operation. That
asynchronous stack identifies the replacement but not the original preparation
caller. Neither attempt qualifies native playback or establishes a graphics
cause. Artifacts are under `.build/playback-graphics-native-33dfae7f` and
`.build/playback-graphics-native-instance-trace`.

Temporary DEBUG-only entry hooks and a sustained-test trace captured requested
frame ranges and synchronous callers before the operation queue lost that
context. They were diagnostic instrumentation, not a production fix, and were
removed after establishing the clock-focus caller.

**Clock-focus transport restarts.** Two further approved native diagnostics
isolated the early processor replacement. `prepare-origin` failed after 28.203
test seconds with a second full-program preparation, not the one-frame
`prepareForEditing` path. `transport-origin` captured its synchronous origin:
`EpisodeClockDisplay` focus loss called `seekDisplayClock`, then
`seekEnabledTracks`, `playTransport`, and `playProductionMix`. The second
transport request had no explicit interval or repeat setting, unlike the test's
initial `0...880`, nonrepeating request.

The clock can gain native focus automatically and retain its initial draft
while playback advances. Opening the effect editor then blurred that unedited
field, sought the stale time, and restarted playback. The clock and shared
seconds transport now distinguish user text edits from automatic display
updates. Focus loss seeks only an edited draft; Return explicitly submits once,
so a subsequent focus loss does not resubmit it. Existing seek validation and
error reporting are retained.

A focused VM regression first reproduced the stale seek from 2 seconds back to
the unedited 1-second draft. After the fix, all 12
`AudioTimelineControlsTests` passed, including edited focus loss, explicit
Return, and no duplicate submission. The owned-window test helper now sends
Return directly to that window and requires its native field editor as first
responder; app-level event routing had instead sent Return to another key
window in the new tests. The earlier Return failures are not evidence of a
production keyboard-routing bug. Baseline and passing results are preserved in
`.build/playback-transcript-cuts-ww-ui-1-clock-baseline.xcresult` and
`.build/playback-transcript-cuts-ww-ui-1-clock-fixed-owned-return.xcresult`.

Before that fix, a separate seed-23, three-case VM1 comparison using the
preparation-entry trace also passed every final check. Minimum reserves were
7,737 / 8,633 / 8,599 frames; 60 program seconds took
92.275 / 94.147 / 94.501 wall seconds. No unexpected preparation occurred in
that run. The two native traces are under
`.build/playback-graphics-native-prepare-origin` and
`.build/playback-graphics-native-transport-origin`. The proven clock restart is
distinct from the original paravirtual-GPU hang and the two VM underruns;
fixing it alone does not establish their cause.

**Native shutdown and checker controls.** The next approved native seed-23
run, `clock-focus-fixed`, retained the original processor through at least
840 program seconds, 1,135 parameter edits, 5,958 captures, and 14 saves.
Its latest minimum reserve was 8,462 frames. At natural completion, however,
the main actor entered `AlignmentAudioPlayback.stop()` and stalled inside
`AVAudioPlayerNode.stop`, through `AVAEDispatchQueueTimer::CancelTimer` and
Thread Performance Checker's `libRPAC` semaphore interposer. Two samples
captured CPU-active backtrace symbolization; the second labeled the executing
queue `TPC issue queue`. The test exceeded its 1,100-second allowance without
reaching final checks. This is not the original Core Animation/paravirtual-GPU
IPC stack and is not a full-soak pass. Artifacts are under
`.build/playback-graphics-native-clock-focus-fixed`. WindowServer sampling was
unavailable because noninteractive sudo required authentication.

The opt-in
`FlattenedPlaybackHostedTests.generatedPlayerCompletionStopDiagnostic()`
isolates AVFAudio with generated silence, without mixer effects or transcript
layout. Enable `WW_PLAYER_STOP_DIAGNOSTIC=1` only for an explicitly authorized,
leased diagnostic. Defaults are 512 immutable 512-frame buffers at 48 kHz.
`WW_PLAYER_STOP_CALLBACKS=0` omits played-back callbacks;
`WW_PLAYER_STOP_PAUSE_FIRST=0` stops the player before pausing the engine.
The test reports whether `libRPAC` is actually loaded, completion counts,
player sample time, and stop latency. Buffer-count/frame overrides are bounded
by the test and are diagnostic controls, not equivalent real-time workloads.

Native controls completed all 512 played-back callbacks before stopping:

| Thread Performance Checker | Stop order | Player stop |
| --- | --- | --- |
| Injected | Pause engine, stop player | 1.891 s |
| Absent, verified from loaded images | Pause engine, stop player | 36.189 ms |
| Loaded, verified from loaded images | Stop player, pause engine | 1.869 s |

The instrumented baseline xcresult also records an internal priority-inversion
warning: a User-interactive thread waiting on Default-QoS work. These controls
establish checker amplification for the short test, not the cause of the
full-length stall. Reversing stop order did not meaningfully help; production
stop ordering and per-buffer completion semantics remain unchanged.
The checker-off control changes only a scratch xctestrun's `libRPAC` injection,
not the project scheme or production behavior.
Artifacts use the native tags `player-stop-512-frame-control`,
`player-stop-512-no-tpc-control`, and `player-stop-512-player-first`.
An earlier compressed control with 80,000 one-frame buffers delivered no
played-back callbacks before its 30-second deadline and then took 13.320 s
to stop. That failed diagnostic is not valid audible-completion qualification
or evidence that production playback accumulates those buffers.

A full seed-23 native checker-off control then completed all 880 program
seconds in 880.718 wall seconds; the complete test took 913.736 s and exited
successfully. It retained an 8,445-frame minimum render reserve, completed 598
explicit and 598 observed parameter edits, 6,286 captures, 33,403 layout
iterations, and 15 in-playback saves. All final recipe-count, adaptive-tile,
verified-save, Undo/Redo, parameter-recall, original-byte integrity, and disposal
checks passed. The xcresult contains no runtime warnings, and the watchdog
needed no captures. Evidence is under
`.build/playback-graphics-native-clock-focus-fixed-no-tpc-control`.
The original audio-output implementation was unchanged, and the scheme's
checker remains enabled. This strengthens the evidence for diagnostic influence
on the native completion stall; it does not prove that the original VM GPU hang
or independent VM underruns are fixed. The successful run included the temporary
entry tracing, which was subsequently removed without changing transport logic.

After removing that tracing, a fresh build passed 28 tests across the clock
controls, flattened playback, persistent cycles, and failed-fixture disposal
suites on VM1 in 80.627 s (42 executions including parameterized cases).
Thread Performance Checker remained enabled. The no-callback shutdown control
also completed its generated stream and stopped in 27.332 ms on that guest;
this is not a matched comparison with the native controls. The xcresult retains
FocusState and QoS runtime warnings, so this is not warning-free qualification.
The collected result and log use
`.build/playback-transcript-cuts-ww-ui-1-final-clock-and-stop`.

### Supplemental-source starvation during actual-show playback

A separately authorized local reproduction on November 11, 2026 captured a
different failure: all five raw source windows drained at about 14 seconds.
One-second preparation windows took 1.419 seconds most recently, with a
1.522-second maximum. The earlier unprofiled report stopped near 20 seconds
with the same empty-raw-queue signature. The bounded stack capture pointed to
supplemental native-window admission and verification, not primarily envelope
evaluation. Profiling can perturb timing; these are not matched wall-time
benchmarks. Evidence uses `.build/reported-underrun-profile-20261111-1227`.

The supplemental scheduler now reuses a bounded native PCM window across its
4,096-frame resampling chunks within one read and clip occurrence. Coverage
comes from the renderer's exact source-phase and sinc-support calculation.
Every native read still goes through witnessed decoding, format checks, and
live admission before and after the read. Access is checked again after the
occurrence is rendered. Nothing is retained between scheduler reads; the
configured native-window bound, storage cap, consumer retention, live mixer
controls, and 250 ms rendered reserve are unchanged.

A one-second generated 44.1/48 kHz clip previously performed 24 live access
checks; it now performs three. At 192 kHz it performs nine, spanning four
bounded native reads rather than enlarging the configured limit. PCM and
lossless M4A cases preserve fade samples bit-for-bit across arbitrary chunks
and seeks, reject subsequent revocation, and reject revocation at final
delivery. The focused renderer, supplemental scheduler, native preparation,
and envelope suites passed with two optional MP3 cases skipped because no
encoder was configured. The previously documented supplemental-placement
fixture that requests playback outside Episode Start/End remains excluded;
an initial run still reproduced that unrelated failure.

Generated one-second 44.1/48 kHz timings improved only from 149-162 ms to
127-136 ms with the fixture's cheap admission callback; those measurements
do not establish real-show throughput. Local build and focused results are
under `.build/supplemental-batching-{app-build,qualified}.log`.

The authorized updated-app capture (build `20261111173358066`) did not qualify
the intro fix: the automated clock edit displayed zero but did not commit the
seek, and playback advanced from the restored position near 81 seconds to
97.550 seconds. It stopped after 798,656 consumed frames (16.639 seconds).
Unlike the original starvation, all five raw windows were still queued:
preparation last/max were 484/767 ms, source wait max was 0.025 ms, DSP
last/max were 8.150/56.831 ms, and enqueue last/max were 3.971/58.470 ms.
This is the separate rendered-output exhaustion signature, not evidence that
the intro now passes. The profile includes repeated waits inside AVFAudio's
`lastRenderTime` engine lock on the output queue. Evidence is under
`.build/supplemental-batching-{profile.txt,audio.log,sampler.log}`. Actual
playback reliability remains unqualified; no further actual-show playback is
authorized by that completed attempt.

After the user requested reopening and manually controlling Play, a second
60-second capture recorded three underruns with four or five raw windows still
queued. Source-wait maxima stayed below 0.020 ms, while enqueue maxima reached
23-66 ms. The output queue repeatedly slept inside
`AVAudioNodeImplBase::GetAttachAndEngineLock` when reading `lastRenderTime`.
Those captures are `.build/supplemental-batching-manual-{profile.txt,audio.log}`.
They do not establish three identical start positions.

The output graph now samples the device clock once per watchdog tick for both
refill and deadline decisions, and once per append for both diagnostics and
validation. Previously each operation requested it twice. This removes
redundant engine-lock acquisitions without caching device time, changing the
deadline rules, moving work into the audio callback, or enlarging the reserve.

VM `ww-ui-1` (Virtualization.framework, macOS 27, four vCPUs) passed the focused
flattened-playback and 32-second sustained live-edit regression with dirty
`81be3fc2` plus these changes: nine test methods passed, one opt-in completion
diagnostic skipped; the parameterized playback method exercised both source
and production modes. The sustained run completed in 32.067 seconds with
8,970 minimum buffered frames, three native inserts, dense transcript layout,
live edits, verified saves, and source-integrity checks. Its result is
`.build/playback-clock-vm-result.xcresult/result.xcresult`, with the guest copy at
`~/ww-uitest-runs/playback-source-clock-33dfae7f-20261111/result.xcresult`.
As in the earlier checker investigation, only the scratch `.xctestrun` omitted
Thread Performance Checker injection; repository checker settings were not
changed. This is functional VM evidence, not actual-show or physical-device
performance qualification.

The combined editing build `20261111180850080` was subsequently reopened for
an explicitly approved, user-controlled 60-second actual-show capture. Two
underruns occurred during sampling, at 13:11:14 and 13:11:27 on November 11,
2026. Both retained four raw windows; source-wait maxima were 0.021/0.019 ms,
DSP maxima were 12.744/14.344 ms, and enqueue maxima were 62.452/25.764 ms.
The profile still contains output-queue waits inside `lastRenderTime` from
both watchdog and append validation. Removing duplicate queries did not
eliminate this sampled output-exhaustion failure.

A later replay remained active at Episode Time 1:00.562 and was manually stopped
at 1:05.229 to bound playback. The user confirmed that this replay started at
zero and remained audibly uninterrupted. A follow-up audio-log read through
13:12:59 contained only the two earlier underruns. This qualifies a bounded
intro replay, not whole-show reliability or elimination of the sampled
failure. The contrast is consistent with profiling perturbation but does not
prove that sampling caused the failures; the exact final replay start was not
captured independently. Evidence is under
`.build/playback-clock-manual-{profile.txt,audio.log,sampler.log}` and
`.build/playback-clock-manual-followup-audio.log`. No further playback was
initiated.

The same suite has a separately gated
`fifteenMinuteEpisodeWithStockCompressionEQEditingAndSaves()` test. Enable
`WW_EPISODE_SOAK_TESTS=1` only on a ready, leased VM and set
`WW_EPISODE_SOAK_MEDIA` to an explicitly staged directory containing
`reader-one.wav` and `reader-two.wav`. Use authorized, reusable speech recordings
with at least 920 seconds per track, converted to 48 kHz mono PCM WAV. Tests do
not download media or discover user recordings. Keep downloaded media outside
the repository and record its provenance and reuse terms with the run evidence.

The test sets actual Episode Start/End to 0 and 900 seconds, starts cold adaptive
playback, and runs in real time. Each speaker bus and the master bus have active
Apple Dynamics Processor compression and Parametric EQ, for six stock inserts.
Parameter edits and normal editor observation continue through the episode,
with saves every minute beginning at second 30 and repeated transcript-layout
CPU work. Per-minute progress, elapsed wall time, all 180 adaptive tiles, normal
completion, retained processor identity, Undo/Redo, parameter recall, verified
saves, accepted timing and original-byte integrity are checked.

Allow at least 1,200 seconds per test invocation in Xcode and use separate
30-minute GUI leases for repeated passes. Every invocation creates fresh copied
sources and caches; do not loop a short warmed audio buffer and call it a
15-minute test. The existing 32-second generated-media regression remains
available without any external speech fixtures.

## Prepare the build

Load `source "$HOME/.shell/exports-core.sh"` before each local shell command.
Build on the development Mac, not in the guest, with isolated DerivedData and
two build workers. Keep the editing app's bundle separate. Choose the plan before
building: its selection and environment are embedded in the generated `.xctestrun`.

```sh
xcodebuild build-for-testing \
  -project WaveWrangler.xcodeproj -scheme WaveWranglerUITests \
  -testPlan PoC \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData-ui -jobs 2 \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

swift build --package-path Packages/WaveWranglerKit \
  --scratch-path .build/swiftpm --jobs 2 --product wwpersist-probe
```

Use `-testPlan Regression` instead for a broader functional shard. Rebuild for
Accessibility or Performance rather than assuming a CLI selector overrides a
PoC `.xctestrun`. If hosted tests are also needed, build their target last and
confirm its plugin is present before staging.

Check generated metadata with
`python3 scripts/test-ui-plans.py --products .build/DerivedData-ui/Build/Products`.
Xcode names these files with the plan, such as
`WaveWranglerUITests_PoC_macosx27.0-arm64.xctestrun`. A pre-plan
`WaveWranglerUITests_macosx27.0-arm64.xctestrun` may remain in reused DerivedData;
it does **not** establish the new plan selection or audit admission.

Record the exact commit and whether the working tree is dirty. A dirty-tree
run is development feedback, not exact-commit qualification. Do not commit or
push solely to obtain a test label without user authorization.

Copy the signed Products and the `wwpersist-probe` executable to a unique
per-run guest directory under `~/ww-uitest-runs/`, staging in a temporary
directory and renaming it only after transfer verification. Do not overwrite
another run. Check `rsync -c` equality and verify the app and test runner
signatures with `codesign --verify --deep`. Confirm that the `.xctestrun`
contains `WaveWranglerUITests`, the intended plan, its actual test selection,
and the expected `WW_UI_ACCESSIBILITY` value.

Only synthetic fixtures belong in the VMs. Never mount or copy user
recordings, transcripts, or model weights without separate approval.

## Run and collect

Recheck the guest's unlocked console, display-awake assertion, Xcode
first-launch status, and `~/ww-uitest-runs/gui-lock status` before dispatch.
Use the existing lease helper from `scripts/gui-lock`; do not delete its
guard or another run's ticket.

On the chosen guest, set `RUN` to the absolute per-run directory, `SHA` to
the recorded commit, and `TEST_RUN` to the exact verified plan-specific
`.xctestrun` basename. This runs the plan embedded during build:

```sh
test -x "$RUN/wwpersist-probe"
TEST_RUNNER_WW_PROBE="$RUN/wwpersist-probe" \
TEST_RUNNER_SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
  ~/ww-uitest-runs/gui-lock run \
    --lane refinement --class pr --sha "$SHA" --dir "$RUN" \
    --result "$RUN/result.xcresult" --lease-minutes 30 --queue-timeout 3600 -- \
    xcodebuild test-without-building \
      -xctestrun "$RUN/Products/$TEST_RUN" \
      -destination 'platform=macOS,arch=arm64' \
      -parallel-testing-enabled NO \
      -resultBundlePath "$RUN/result.xcresult"
```

For a focused shard, build the appropriate broad plan and add
`-only-testing:"WaveWranglerUITests/$TEST_CLASS"` to that guest invocation.

One invocation owns one lease. Release it before analysis or rebuilding.
Split full suites into bounded shards rather than holding a host between
runs. Keep both VMs within eight vCPUs combined and coordinate host builds
with test work.

Retrieve the `.xcresult` and inspect it locally with `xcrun xcresulttool`.
Record host, VM configuration, source revision, selected classes, pass/fail/
skip counts, and result path. A lost or locked VM, missing fixture probe,
unverified transfer, or stale runner is an environment-invalid run, not a
product failure or pass. Stop on a repeated environmental failure instead
of repeatedly retrying or switching to a physical host.
