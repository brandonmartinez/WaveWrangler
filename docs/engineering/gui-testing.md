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
crosses at least seven five-second tiles without increasing playback buffers.

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

Record the bounded numeric `SUSTAINED_PRODUCTION` summary and actual executed
test identities/counts. Repeat with two or three fresh fixtures for qualification
evidence. Retain the `FlattenedPlaybackHostedTests` negative controls for
intentional queue starvation, refusal of externally changed sources, and
stop/stale-producer invalidation. Existing deterministic queue and control
horizon tests remain responsible for their bounds.

These are VM functional regression results, not supported physical-hardware
performance qualification.

#### Full 15-minute episode soak

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
