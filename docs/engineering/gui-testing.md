# GUI test pipeline

Ordinary hosted/UI execution uses ready, exclusively leased
[macOS VMs](ui-test-vm-hosts.md), normally `ww-ui-1` or `ww-ui-2`.
Neither the development desktop nor Mac mini is an unavailable-VM fallback.
Build and inspect results outside the lease; one invocation owns one lease.
Follow the host guide's [per-feature lifecycle](ui-test-vm-hosts.md#per-feature-lifecycle):
inspect ownership and guest cleanliness, start and verify, test, preserve evidence,
clean owned artifacts, then stop owned guests and verify they stopped.

## Select a plan, not an assumed full suite

| Plan | Purpose | Wrapper selection |
| --- | --- | --- |
| PoC | Working core-feature smoke, not broad accessibility qualification | `scripts/test.sh --ui` |
| Regression | Broad functional native interaction and lifecycle | `--ui-profile=regression` |
| Accessibility | Audits, appearance/layout, AX, keyboard and VoiceOver coverage | `--ui-profile=accessibility` |
| Performance | Opt-in responsiveness sampling, separate from feature correctness | `--ui-profile=performance` |

These wrapper commands run on their **current host**; do not invoke them on
the development desktop to execute GUI tests. Use staged Products below.
The shared scheme defaults to PoC. No default command runs the complete bundle.
Plan contents overlap deliberately; maintained inventory is in `TestPlans/`.

A focused `--ui -only-testing:WaveWranglerUITests/Class/test` implicitly selects
Regression unless a profile is explicit. Xcode intersects selectors with the
built plan, so a selector does not override PoC metadata or admit accessibility.
Check actual executed identities and nonzero counts, not exit status alone.
For broad coverage, build and run each relevant plan/shard explicitly.

Feature audits log `ACCESSIBILITY DEFERRED` unless admitted by
`WW_UI_ACCESSIBILITY=1`; dedicated audit/VoiceOver cases may skip without it.
Deferral is not a pass, waiver or weaker threshold. Full Keyboard Access,
VoiceOver and guest permissions remain separate setup requirements.
Real-speech/model, soak and screenshot tests have their own opt-ins.

`python3 scripts/test-ui-plans.py --static` verifies inventory and coverage.
Without `--static`, the checker also exercises CLI routing using stand-ins
without launching an app. `--products` checks generated plan metadata/products.
Use it instead of copying a fixed test count into evidence.

## Build and stage

On the development Mac, choose the exact plan before building:

```sh
xcodebuild build-for-testing \
  -project WaveWrangler.xcodeproj -scheme WaveWranglerUITests \
  -testPlan Regression -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData-ui -jobs 2 \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

swift build --package-path Packages/WaveWranglerKit \
  --scratch-path .build/swiftpm --jobs 2 --product wwpersist-probe

python3 scripts/test-ui-plans.py --products .build/DerivedData-ui/Build/Products
```

Keep the editing app's DerivedData separate and coordinate concurrent scratch/
worker usage. For hosted tests use scheme `WaveWranglerHostedTests`; when sharing
Products, build that scheme last and verify its plugin is present before staging.

Select the exact verified plan-specific `.xctestrun` basename. Its SDK suffix
varies; a stale pre-plan `WaveWranglerUITests_macosx...xctestrun` in reused output
does not establish the requested selection or audit admission.
Record SHA and dirty patch identity. Dirty runs are development feedback,
not clean-commit qualification; do not commit/push merely to obtain a label.

Copy signed Products and `wwpersist-probe` into a unique guest run directory
under `~/ww-uitest-runs/`, initially `Products.incoming`. Verify byte equality
with checksum-mode rsync (`-c`), app and runner signatures
(`codesign --verify --deep`), and the probe's executable status. Only then rename
the incoming directory atomically to `Products`. Never overwrite another run.
Check target, selected tests and `WW_UI_ACCESSIBILITY` in the staged metadata.

Use synthetic fixtures. Do not mount/copy user recordings, transcripts or model
weights, or stage external speech without separate authorization.

## Run and collect

Recheck SSH, unlocked console, display-awake assertion, Xcode first-launch and
lease status immediately before dispatch. The
[host guide](ui-test-vm-hosts.md) defines readiness and process ownership.

On the guest set `RUN` to its absolute unique run path, `SHA` to the recorded
commit and `TEST_RUN` to the verified plan-specific basename:

```sh
test -x "$RUN/wwpersist-probe"
TEST_RUNNER_WW_PROBE="$RUN/wwpersist-probe" \
TEST_RUNNER_SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
  ~/ww-uitest-runs/gui-lock run \
    --lane functional-regression --class pr --sha "$SHA" --dir "$RUN" \
    --result "$RUN/result.xcresult" --lease-minutes 30 --queue-timeout 3600 -- \
    xcodebuild test-without-building \
      -xctestrun "$RUN/Products/$TEST_RUN" \
      -destination 'platform=macOS,arch=arm64' \
      -parallel-testing-enabled NO \
      -resultBundlePath "$RUN/result.xcresult"
```

For a focused UI shard add
`-only-testing:WaveWranglerUITests/<Class>/<method>` to that invocation.
Swift Testing hosted selectors require the trailing `()` on method names.
Use one lease per invocation and release before rebuilding, diagnosis or
collecting evidence. Split large suites into bounded shards. Keep the two guests
within eight vCPUs combined and coordinate competing host builds.

`scripts/gui-lock` is the lease authority. Never unlink the persistent
`.gui.lock.guard`, another ticket or an active lease. Reclaim stale/dead recorded
ownership only through the helper. A successful old run does not grant a lease.

Retrieve the `.xcresult`, then inspect locally:

```sh
xcrun xcresulttool get test-results summary --path /path/to/result.xcresult
xcrun xcresulttool export attachments --path /path/to/result.xcresult \
  --output-path /path/to/attachments
```

Record source SHA/patch, VM configuration, selection, executed identities and
pass/fail/skip counts plus result path. Preserve the first failure and distinguish
product assertions from environment-invalid runs: locked/lost guest, stale
runner, missing probe or unverified transfer cannot be counted as pass/fail
product qualification. Stop repeated environmental retries and fix/report
readiness; do not switch to a physical host. See [quarantine](gui-flake-quarantine.md)
for the sole narrow selection exception.

## Reproduce documentation screenshots

[`DocumentationScreenshotUITests`](../../WaveWranglerUITests/DocumentationScreenshotUITests.swift)
is an explicit opt-in Regression test. It uses generated recordings, music and
seeded synthetic transcripts; no user media or local model is required.
It drives actual controls, then attaches native window/sheet screenshots with
`keepAlways`. It is not a mock rendering or accessibility qualification.

Use a **2304 by 1440, 1x** guest display so the compact speaker lanes, music
and complete docked mixer fit together. Verify the guest's actual logical
resolution and backing scale, not just the VM's configured display size.
The test selects dark appearance, fits the timeline and resizes the bottom
pane through native interaction.

Build/stage Regression using the procedure above. In the **guest** invocation,
set `TEST_RUNNER_WW_DOCUMENTATION_SCREENSHOTS=1` alongside the probe/worker
variables and select:

```text
-only-testing:WaveWranglerUITests/DocumentationScreenshotUITests/testCaptureProductGuideScreenshots
```

The test checks runner environment `WW_DOCUMENTATION_SCREENSHOTS=1`; verify
the result executed the method without an opt-in skip. Use a fresh result
bundle and one leased invocation, not desktop capture.

Export attachments with `xcresulttool export attachments` as above. Its
`manifest.json` maps semantic attachment names to exported files; do not assume
the exported filenames are stable. Inspect the eight images, then copy only
the intended PNGs to `docs/assets/screenshots/<name>.png`:

| Attachment name | Surface |
| --- | --- |
| `episode-workspace` | Main production workspace |
| `library` | Show/episode organization |
| `recordings-and-speakers` | Recording and speaker setup |
| `alignment-review` | Alignment details/review |
| `transcript-review` | Transcript and review pane |
| `audio-clips-and-fades` | Supplemental clip and envelope controls |
| `mixer` | Detached production mixer |
| `export` | Delivery sheet |

Retain result/source identity with the capture evidence. Verify images describe
the current product before updating guide links/captions. Do not treat screenshot
success as export, audio-quality or broad regression clearance.

## Opt-in audio and performance diagnostics

The short generated-media production regression is
`SustainedProductionPlaybackHostedTests/adaptiveProductionSurvivesLiveInsertEditingSavingAndTranscriptLayout()`
with `WW_PRODUCTION_TIMING_TESTS=1`. It exercises cold adaptive tiles, native
effects/editor changes, transcript-layout load, real saves, completion and
postplayback Undo/recall. Keep negative controls for starvation, source change
and stale producer/Stop. A reserve summary is not the final test result.

Long-running generated variants are separately admitted with
`WW_SYNTHETIC_EPISODE_SOAK_TESTS`, `WW_TRANSCRIPT_CUT_SOAK_TESTS` and
`WW_TRANSCRIPT_UI_COMPARISON_TESTS`. Read their current source for selectors,
seed/input requirements and actual played duration; do not silently substitute
a warmed short loop or pool unrelated runs into qualification.

`WW_EPISODE_SOAK_TESTS` additionally requires explicitly authorized staged
speech via `WW_EPISODE_SOAK_MEDIA`, not discovery/download of user recordings.
It is a separate media/long-run decision. Model-backed recognition and manual
physical-device experiments are separate again.

Record workload, build, cold/warm state, seed, host contention, actual duration
and completed edit/layout operations when comparing performance.
VM functional/timing evidence does not establish physical-device latency or
supported-hardware performance, and old run logs do not authorize repetition.
