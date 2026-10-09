---
name: "gui-lock-mac-mini"
description: "Use when a WaveWrangler lane needs a GUI run, including XCUITest, an accessibility audit, computer-use, or an app launch. Build on the dev Mac, use one lease on a suitable GUI host, collect the xcresult, and post evidence on the PR. Does NOT authorize GUI work on the user's main working Mac, manual lock holding between runs, or GUI work by reviewers."
---

# Self-serve GUI locks and the host pipeline

Learned in M1 (see `docs/planning/retrospectives/m1.md` §3 #2): a single GUI host with coordinator-relayed lock messages and remote trial-and-error UI iteration was the slowest path. From M2 each lane drives its own GUI runs through a per-host lock; the coordinator sees results only.

## Rules

- **GUI hosts:** the user's Mac mini ("Macsimus": Apple M2 Pro, 12 cores, 32 GiB, macOS 27.0.1) remains the default physical host and the only host for performance/responsiveness gates, VoiceOver and manual accessibility work. It has user consent for UI, XCUITest, accessibility audits, computer-use, temporary VoiceOver and temporary display/accessibility settings (record originals, restore afterwards). Two headless macOS 27 VMs (`ww-ui-1`, `ww-ui-2`) on Macatron are additional hosts for functional XCUITests using synthetic fixtures only; see [`docs/engineering/ui-test-vm-hosts.md`](../../../docs/engineering/ui-test-vm-hosts.md). The user's main working Mac is a GUI host only inside an explicitly user-granted away window (its own lock; never computer-use or VoiceOver; stop on user input). Reach the mini by IP (`ssh -o BatchMode=yes brandonmartinez@192.168.18.8`); never edit `known_hosts`.
- **Products come from a committed, pushed SHA only.** Never label a run with a working-tree name. Before use, verify that the `.xctestrun` names `WaveWranglerUITests`, run `codesign --verify --deep` on the app and the Runner, and check `rsync -c` checksum equality. Copy atomically into a per-run unique folder (`rsync` to `~/ww-uitest-runs/.tmp-<lane>-<sha>-<ts>`, then `mv` to `<lane>-<sha>-<ts>`), and never reuse or overwrite another run's folder. A run that breaks these rules is environment-invalid (2026-10-07: `pr219-final-r1`), not a pass or a product failure.
- **Performance strata** can't be split, so each `ResponsivenessUITests` method gets its own `perf` ticket on the mini of up to 45 minutes, after at least 60 s idle and with the pre-run load below 6. VM timings are never valid for performance gates.
- **One GUI run per lease.** `scripts/gui-lock run` owns one `test-without-building` invocation and releases in a trap. Never hold the GUI while analysing, rebuilding, or preparing another round.
- **Check status before polling lanes.** `gui-lock status` shows the holder, lease age, priority queue, ticket ages and estimated wait.
- **Priority:** `required` (required path / exit gate), then `pr`, then `full` and `perf`; FIFO within a class.
- Every result is labelled with host and SHA. Label VM evidence `VM ww-ui-N (Virtualization.framework, macOS 27, 4 vCPU)`; the mini is not the macOS 26 / 16 GB reference.
- **Reviewers never take the lock or run UI tests.** They review diffs, CI and the evidence the author posts (a reviewer's run collided with the regression runner in M1, #149).
- **Per-PR runs** cover only the UI test classes the PR affects. PRs that change no app UI or test code skip GUI runs.
- **Batching:** a lane may batch several of its own PRs' classes only at one SHA. Never mix unrelated PR binaries.
- **GUI timebox:** after 3 failed counted GUI rounds on one PR, stop and hand off to Lead (design decision or follow-up issue). There is no fourth counted round unless a recorded Lead decision (on the PR and in `decisions.md`) restarts the count. Rounds that never ran (lock stolen, quiet-gate rejection, released before `xcodebuild`) or were environment-invalid don't count.
- **Preflight first:** `.squad/skills/kickoff-preflight` (SSH agent, Automation Mode, clean screen). The direct `ssh -o BatchMode=yes -o ConnectTimeout=8 brandonmartinez@192.168.18.8 true` probe is the Mini readiness gate: when it fails, report its actual authentication or network error once as needs_input and do not loop. Never infer that 1Password is locked from an empty `ssh-add -l` or launchd-agent listing, and never bypass an SSH host-key warning. VM SSH uses a dedicated key, not the 1Password agent; use a VM only after its Xcode license and first-launch checks pass and the smoke run recorded in its [host guide](../../../docs/engineering/ui-test-vm-hosts.md) has passed. The VM service must already be detached from any disposable app/agent session before use, and the VM's own lock must be available.
- **VM display preflight:** check `pmset -g assertions` in the guest for `PreventUserIdleDisplaySleep 1` and verify the console with the fail-closed check in the [host guide](../../../docs/engineering/ui-test-vm-hosts.md). Auto-login does not clear a previously locked console; XCUITest can launch the app but fail to foreground it as `Running Background`. `gui-lock run` also refuses the lease with `VM console locked` when its VirtualMac console is locked or unavailable.

## Pipeline

1. **Bind and build the externally requested exact SHA on the dev Mac** (counts toward the 3-native-build limit, `-jobs 4`, isolated DerivedData). Do not derive this identity from the current checkout: set `PR` and `REQUESTED_SHA` from the PR/main record being tested. `wwpersist-probe` is required by UI test setup; a run without it is **NOT PASS**, even if `xcodebuild` exits zero after skipping tests.
   ```sh
   set -euo pipefail
   source "$HOME/.shell/exports-core.sh"
   source "$HOME/.shell/exports.sh"
   PR=123 # Use main for a main checkpoint.
   REQUESTED_SHA=0123456789abcdef0123456789abcdef01234567 # Full SHA from the PR/main record.
   git fetch origin
   REQUESTED_SHA=$(git rev-parse --verify "${REQUESTED_SHA}^{commit}") ||
     { echo "Requested SHA is not a commit"; exit 1; }
   if [ "$PR" = main ]; then
     test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$REQUESTED_SHA" ||
       { echo "Requested SHA is not current origin/main"; exit 1; }
   else
     PR_RECORD=$(gh pr view "$PR" --json baseRefName,headRefOid --jq '.baseRefName + "\t" + .headRefOid') ||
       { echo "Cannot read PR $PR"; exit 1; }
     test "$PR_RECORD" = "$(printf 'main\t%s' "$REQUESTED_SHA")" ||
       { echo "Requested SHA is not the current main-targeted PR head"; exit 1; }
   fi
   test -z "$(git status --porcelain --untracked-files=all)" || { echo "Working tree not clean"; exit 1; }
   test "$(git rev-parse HEAD)" = "$REQUESTED_SHA" ||
     { echo "Checkout does not match externally requested SHA"; exit 1; }
   COMMIT="$REQUESTED_SHA"
   SHA=${COMMIT:0:12}
   mkdir -p .build
   BUILD_ROOT=$(mktemp -d ".build/gui-build-$SHA-XXXXXXXX")
   PRODUCTS="$BUILD_ROOT/DerivedData/Build/Products"

   xcodebuild build-for-testing -project WaveWrangler.xcodeproj -scheme WaveWranglerUITests \
     -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD_ROOT/DerivedData" -jobs 4 ||
     { echo "build-for-testing failed; do not stage Products"; exit 1; }

   # This is the same synthetic-fixture probe build used by scripts/test.sh --ui.
   swift build \
     --package-path Packages/WaveWranglerKit \
     --scratch-path "$BUILD_ROOT/swiftpm" \
     --jobs 4 \
     --product wwpersist-probe ||
     { echo "probe build failed; do not stage Products"; exit 1; }
   PROBE="$(swift build --package-path Packages/WaveWranglerKit \
     --scratch-path "$BUILD_ROOT/swiftpm" --show-bin-path)/wwpersist-probe" ||
     { echo "Cannot locate newly built probe"; exit 1; }
   test -x "$PROBE" || { echo "Missing executable wwpersist-probe: $PROBE"; exit 1; }

   # Both outputs came from this new build root; a prior SHA's Products/probe cannot satisfy these checks.
   test "$(git rev-parse HEAD)" = "$REQUESTED_SHA" ||
     { echo "HEAD changed during build; do not stage this output"; exit 1; }
   test -z "$(git status --porcelain --untracked-files=all)" ||
     { echo "Working tree changed during build; do not stage this output"; exit 1; }
   set +e # Later steps capture nonzero lease/SSH statuses and inspect them before deciding PASS.
   ```
2. **Atomically stage Products *and the probe* from that successful build in one unique host run folder.** Run this in the same shell as step 1; do not substitute a prior build root or proceed after either build fails. Set `GUI_HOST` to the Mini address or exactly one VM alias, and keep the generated `RUN`, `LANE`, `SHA`, and `RUN_ID` for every artifact and PR record. Do not reuse a previous folder or its logs.
   ```sh
   shopt -s nullglob
   xctestruns=("$PRODUCTS"/WaveWranglerUITests_*.xctestrun)
   test "${#xctestruns[@]}" -eq 1 ||
     { echo "Expected exactly one newly built WaveWranglerUITests xctestrun"; exit 1; }
   plutil -extract WaveWranglerUITests xml1 -o - "${xctestruns[0]}" >/dev/null ||
     { echo "xctestrun does not name WaveWranglerUITests"; exit 1; }
   codesign --verify --deep "$PRODUCTS/Debug/WaveWrangler.app" ||
     { echo "App signature invalid"; exit 1; }
   codesign --verify --deep "$PRODUCTS/Debug/WaveWranglerUITests-Runner.app" ||
     { echo "Runner signature invalid"; exit 1; }

   GUI_HOST=brandonmartinez@192.168.18.8 # for a VM, use ww-ui-1 or ww-ui-2
   LANE=your-lane
   SHARD=your-test-class-or-full-01
   EXPECTED_SKIPS=0 # A nonzero value needs a documented waiver; missing-probe skips are never expected.
   REMOTE_HOME=$(ssh "$GUI_HOST" 'printf %s "$HOME"') ||
     { echo "Cannot read GUI host home"; exit 1; }
   TS=$(date +%Y%m%dT%H%M%S)
   RUN_ID="$LANE-$SHA-$TS"
   TMP="$REMOTE_HOME/ww-uitest-runs/.tmp-$RUN_ID"
   RUN="$REMOTE_HOME/ww-uitest-runs/$RUN_ID"
   LOCAL_MANIFEST=$(mktemp) || { echo "Cannot create identity manifest"; exit 1; }
   {
     printf 'requested_sha\t%s\nactual_sha\t%s\nbuild_root\t%s\nhost\t%s\nlane\t%s\nshard\t%s\nrun_id\t%s\n' \
       "$COMMIT" "$(git rev-parse HEAD)" "$BUILD_ROOT" "$GUI_HOST" "$LANE" "$SHARD" "$RUN_ID"
     shasum -a 256 "$PROBE" &&
       shasum -a 256 "${xctestruns[0]}"
   } >"$LOCAL_MANIFEST" || { echo "Cannot hash new artifacts"; rm -f "$LOCAL_MANIFEST"; exit 1; }

   ssh "$GUI_HOST" "test ! -e '$TMP' && test ! -e '$RUN' && mkdir -p '$TMP/Products'"
   ssh_status=$?
   test "$ssh_status" -eq 0 || { echo "stage mkdir SSH status=$ssh_status"; rm -f "$LOCAL_MANIFEST"; exit "$ssh_status"; }
   rsync -a "$PRODUCTS/" "$GUI_HOST:$TMP/Products/"
   rsync_products_status=$?
   test "$rsync_products_status" -eq 0 || { echo "Products rsync status=$rsync_products_status"; rm -f "$LOCAL_MANIFEST"; exit "$rsync_products_status"; }
   rsync -a "$PROBE" "$GUI_HOST:$TMP/Products/wwpersist-probe"
   rsync_probe_status=$?
   test "$rsync_probe_status" -eq 0 || { echo "probe rsync status=$rsync_probe_status"; rm -f "$LOCAL_MANIFEST"; exit "$rsync_probe_status"; }
   rsync -a "$LOCAL_MANIFEST" "$GUI_HOST:$TMP/identity.tsv"
   rsync_identity_status=$?
   test "$rsync_identity_status" -eq 0 || { echo "identity rsync status=$rsync_identity_status"; rm -f "$LOCAL_MANIFEST"; exit "$rsync_identity_status"; }
   rm -f "$LOCAL_MANIFEST"

   # Verify the copied executable, signed test products, and all xctestruns before making the run visible.
   ssh "$GUI_HOST" "test -x '$TMP/Products/wwpersist-probe' && cd '$TMP' && \
     shasum -a 256 Products/wwpersist-probe Products/WaveWranglerUITests_*.xctestrun > staged-checksums.tsv && \
     codesign --verify --deep Products/Debug/WaveWrangler.app && \
     codesign --verify --deep Products/Debug/WaveWranglerUITests-Runner.app"
   stage_verify_status=$?
   test "$stage_verify_status" -eq 0 ||
     { echo "staged executable/checksum verification status=$stage_verify_status"; exit "$stage_verify_status"; }
   PRODUCTS_CHANGES=$(rsync -a -c --dry-run --itemize-changes "$PRODUCTS/" "$GUI_HOST:$TMP/Products/")
   products_verify_status=$?
   test "$products_verify_status" -eq 0 ||
     { echo "Products checksum transport status=$products_verify_status"; exit "$products_verify_status"; }
   test -z "$PRODUCTS_CHANGES" || { printf '%s\n' "$PRODUCTS_CHANGES"; echo "Products checksum mismatch"; exit 1; }
   PROBE_CHANGES=$(rsync -a -c --dry-run --itemize-changes "$PROBE" "$GUI_HOST:$TMP/Products/wwpersist-probe")
   probe_verify_status=$?
   test "$probe_verify_status" -eq 0 ||
     { echo "probe checksum transport status=$probe_verify_status"; exit "$probe_verify_status"; }
   test -z "$PROBE_CHANGES" || { printf '%s\n' "$PROBE_CHANGES"; echo "probe checksum mismatch"; exit 1; }
   ssh "$GUI_HOST" "mv '$TMP' '$RUN'"
   publish_status=$?
   test "$publish_status" -eq 0 || { echo "stage publish SSH status=$publish_status"; exit "$publish_status"; }
   ```
3. **Run exactly one selected shard under one host lease, reporting only observable statuses.** The remote script does not use `set -e`, a shell wrapper, or a pipe around `xcodebuild`: `gui-lock` permits only direct `xcodebuild test-without-building`, and it renews only when its output log advances. Exporting `TEST_RUNNER_WW_PROBE` in the remote parent propagates it to that executable. `lease_status` is the **helper's** exit status, not a retained raw `xcodebuild` status: it returns 75 on lease loss/expiry after discarding the child status, and can turn a zero child status into 2 if xcresult is missing. The raw child status is **UNKNOWN** here; fully satisfying #389's raw-status requirement needs a separate helper code change outside this docs-only recipe.
   ```sh
   TEST_CLASS=YourUITestClass # use a class list shard for full suites
   LEASE_CLASS=pr # use full for full-suite shards
   printf -v REMOTE_ARGS ' %q' "$RUN" "$LANE" "$COMMIT" "$SHA" "$PR" "$SHARD" "$TEST_CLASS" "$EXPECTED_SKIPS" "$LEASE_CLASS"
   ssh_status=0
   ssh "$GUI_HOST" "bash -s --$REMOTE_ARGS" <<'REMOTE' || ssh_status=$?
   set -u -o pipefail
   RUN=$1; LANE=$2; COMMIT=$3; SHA=$4; PR=$5; SHARD=$6; TEST_CLASS=$7; EXPECTED_SKIPS=$8; LEASE_CLASS=$9
   STATUS="$RUN/command-status.tsv"
   printf 'run_id\t%s\nrequested_sha\t%s\nshort_sha\t%s\nhost\t%s\nlane\t%s\nshard\t%s\nexpected_skips\t%s\n' \
     "$(basename "$RUN")" "$COMMIT" "$SHA" "$(hostname)" "$LANE" "$SHARD" "$EXPECTED_SKIPS" >"$STATUS"
   printf 'preflight_probe\t' >>"$STATUS"
   test -x "$RUN/Products/wwpersist-probe"; probe_status=$?
   printf '%s\n' "$probe_status" >>"$STATUS"
   if [ "$probe_status" -ne 0 ]; then exit "$probe_status"; fi
   shopt -s nullglob
   xctestruns=("$RUN"/Products/WaveWranglerUITests_*.xctestrun)
   if [ "${#xctestruns[@]}" -ne 1 ]; then
     printf 'preflight_xctestrun\t1\n' >>"$STATUS"
     exit 1
   fi
   ~/ww-uitest-runs/gui-lock status >>"$RUN/lease.log" 2>&1
   lock_status_status=$?
   printf 'lease_status_preflight\t%s\n' "$lock_status_status" >>"$STATUS"
   if [ "$lock_status_status" -ne 0 ]; then exit "$lock_status_status"; fi

   export TEST_RUNNER_WW_PROBE="$RUN/Products/wwpersist-probe"
   ~/ww-uitest-runs/gui-lock run \
     --lane "$LANE" --class "$LEASE_CLASS" --pr "$PR" --sha "$SHA" --dir "$RUN" \
     --result "$RUN/result.xcresult" --output "$RUN/xcodebuild.log" \
     --lease-minutes 30 --queue-timeout 3600 -- \
     xcodebuild test-without-building \
       -xctestrun "${xctestruns[0]}" \
       -destination "platform=macOS,arch=arm64" -parallel-testing-enabled NO \
       -only-testing:"WaveWranglerUITests/$TEST_CLASS" \
       -resultBundlePath "$RUN/result.xcresult" \
     >>"$RUN/lease.log" 2>&1
   lease_status=$?
   printf 'lease_status\t%s\nxcodebuild_raw_status\tunknown\n' "$lease_status" >>"$STATUS"
   if test -d "$RUN/result.xcresult"; then
     printf 'xcresult\tpresent\n' >>"$STATUS"
   else
     printf 'xcresult\tmissing\n' >>"$STATUS"
   fi
   if [ "$lease_status" -eq 0 ] && ! test -d "$RUN/result.xcresult"; then exit 2; fi
   exit "$lease_status"
   REMOTE
   printf 'ssh\t%s\n' "$ssh_status"
   test "$ssh_status" -eq 0 || echo "remote run failed; retrieve $RUN for diagnosis, never mark PASS"
   ```
   For a full suite, use a declared class-to-host shard plan: one `RUN_ID`, one `SHARD`, one lease and one
   `.xcresult` per `xcodebuild` invocation. Keep the planned and completed shard counts together; a missing or
   overwritten shard is **NOT RUN**, not a pass. The helper renews the lease only while the wrapped PID is alive and its output log advances. It verifies the
   xcresult, restores `$RUN/restore-settings.sh` when present, kills only recorded run PIDs, and releases on
   `EXIT`, `INT`, or `TERM`. A queue timeout keeps the ticket in place and continues waiting.
4. **Retrieve and fail closed on results, including unexpected skip identities.** Retrieve the status log, identity,
   test log, xcresult and checksum manifest as one artifact set; do not associate a prior run's logs with this
   SHA. The result remains **NOT PASS** if a required artifact, requested SHA, status, or count is missing.
   ```sh
   LOCAL_RUN=".build/gui-runs/$RUN_ID"
   mkdir -p .build/gui-runs
   mkdir "$LOCAL_RUN" || { echo "Local run already exists; refuse stale artifacts"; exit 1; }
   rsync -a "$GUI_HOST:$RUN/" "$LOCAL_RUN/"
   retrieve_status=$?
   test "$retrieve_status" -eq 0 || { echo "artifact retrieval status=$retrieve_status"; exit "$retrieve_status"; }
   printf 'retrieve_rsync\t%s\nremote_ssh\t%s\n' "$retrieve_status" "$ssh_status" >"$LOCAL_RUN/transport-status.tsv"
   grep -Fx "requested_sha	$COMMIT" "$LOCAL_RUN/command-status.tsv" >/dev/null &&
     grep -Fx "actual_sha	$COMMIT" "$LOCAL_RUN/identity.tsv" >/dev/null ||
     { echo "artifact SHA identity mismatch or missing"; exit 1; }
   grep -Fx 'lease_status	0' "$LOCAL_RUN/command-status.tsv" &&
     grep -Fx 'xcresult	present' "$LOCAL_RUN/command-status.tsv" &&
     grep -Fx 'xcodebuild_raw_status	unknown' "$LOCAL_RUN/command-status.tsv" &&
     test "$ssh_status" -eq 0 &&
     test -d "$LOCAL_RUN/result.xcresult" ||
     { echo "lease/SSH status nonzero or result/status missing; NOT PASS"; exit 1; }

   xcrun xcresulttool get test-results summary --path "$LOCAL_RUN/result.xcresult" --format json >"$LOCAL_RUN/summary.json"
   summary_status=$?
   test "$summary_status" -eq 0 || { echo "xcresult summary status=$summary_status"; exit "$summary_status"; }
   passed=$(plutil -extract passedTests raw "$LOCAL_RUN/summary.json")
   failed=$(plutil -extract failedTests raw "$LOCAL_RUN/summary.json")
   skipped=$(plutil -extract skippedTests raw "$LOCAL_RUN/summary.json")
   counts_line=$(printf 'run_id=%s host=%s requested_sha=%s shard=%s passed=%s failed=%s skipped=%s expected_skips=%s\n' \
     "$RUN_ID" "$GUI_HOST" "$COMMIT" "$SHARD" "$passed" "$failed" "$skipped" "$EXPECTED_SKIPS")
   printf '%s\n' "$counts_line" >"$LOCAL_RUN/counts.txt"
   cat "$LOCAL_RUN/counts.txt"
   case "$passed:$failed:$skipped:$EXPECTED_SKIPS" in *[!0-9:]*)
     echo "invalid or absent xcresult counts; NOT PASS"; exit 1 ;;
   esac
   if [ "$failed" -ne 0 ] || [ "$skipped" -ne "$EXPECTED_SKIPS" ]; then
     echo "failed or unexpected skipped tests; retain original shard artifact as NOT PASS"
     exit 1
   fi
   ```
   A matching count is not proof that each skipped test was the declared waiver. Before calling a shard with
   `EXPECTED_SKIPS` greater than zero PASS, manually export and inspect the exact test-result selector below.
   Reject the shard if any skipped test is not the named waiver, or if any skip reason includes
   `WW_PROBE is not set`; this is deliberately fail-closed because a portable documentation snippet cannot
   reliably normalize every `xcresulttool` test-result schema.
   ```sh
   xcrun xcresulttool get test-results tests \
     --path "$LOCAL_RUN/result.xcresult" --format json >"$LOCAL_RUN/tests.json" ||
     { echo "Cannot inspect skipped-test identities; NOT PASS"; exit 1; }
   # Manually verify every skipped identity/reason in tests.json against the approved waiver list.
   grep -F 'WW_PROBE is not set' "$LOCAL_RUN/tests.json" >/dev/null &&
     { echo "WW_PROBE propagation skip detected; NOT PASS"; exit 1; }
   ```
5. **Post on the PR:** exact requested and actual SHA, unique build root, `RUN_ID`, host, planned/completed shard counts,
   classes, pass/fail/skip/expected-skip counts, SSH and helper lease statuses, raw xcodebuild status **UNKNOWN** (not independently exposed), xcresult location,
   and any new audit finding versus the pinned waiver baseline. Do not call this a product or gate success until
   every required shard has its own matching artifact and zero unexpected skips.

For VM runs, use only synthetic fixtures; never mount or copy the user's recordings or test media.
Build on the development Mac, not in the guest. Keep the two VMs at four vCPUs
each (at most eight virtual CPUs combined); avoid concurrent CPU-heavy host
builds. Once validated, VM hosts have independent locks and can run functional
XCUITests without taking over the user's desktop. They do not replace the mini for
performance measurements or manual GUI/a11y work.

## Lock helper reference

`~/ww-uitest-runs/gui-lock` lives on each GUI host, outside the repo (the lease helper from `scripts/gui-lock` has been live on the mini since 2026-10-07, after #230 / `9f7a0f7`; the legacy copy is backed up beside it). Install the same helper before using any other GUI host.

| Command | Effect |
|---|---|
| `run --lane L --class C --sha S --dir RUN_DIR --result PATH -- COMMAND...` | Priority FIFO ticket, renewable lease, exactly one wrapped command, xcresult check, scoped cleanup and automatic release |
| `status` | Holder, lease age/remaining time, stale state, and queue positions/ages/ETAs |

A lease defaults to 30 minutes and may be configured up to a hard maximum of 45. The next waiter atomically
reclaims an expired lease or a lease whose recorded PID died, logs `reclaimed`, and kills only the stale holder's
recorded PIDs. A lane rejoins the back of its priority FIFO for every additional run.

### Cutover from the legacy helper

Wait for the legacy holder and flat-file queue to drain or hand off to their owners; never erase live state
to force installation. Back up `~/ww-uitest-runs/gui-lock` before installing the new helper, then run
`gui-lock status`. The manual acquire/release interface and flat-file tickets are not compatible with this
lease helper. Test it first with `GUI_LOCK_ROOT` in a temporary sandbox; do not deploy until approved.

Full suites use class `full` and must be split by test class into shards expected to complete within 30 minutes.
Each shard is a separate `gui-lock run` ticket and xcresult. If a shard exceeds 30 minutes, split its class list
again rather than increasing the lease; the 45-minute maximum is for a known indivisible class.

## Hygiene (M1 lessons)

- Close other windows; keep audited windows on the primary display (occluded or straddling windows produced false contrast findings).
- Open documents with `app.launchOnce(opening:)`, never `launch()` then `open(url)` (two app processes, #135).
- Computer-use can't commit SwiftUI text fields with `set_value`/`type_text` in the background (send one `press_key` per character) and can't open pop-up or menu-bar menus: cover those steps with XCUITest. Near open/save panels, send keystrokes one at a time and verify.
- Before blaming the product for an odd failure, check for foreign WaveWrangler processes (`pgrep`, unified log `Successfully spawned WaveWrangler[`).
