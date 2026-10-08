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
- **Preflight first:** `.squad/skills/kickoff-preflight` (SSH agent, Automation Mode, clean screen). If SSH to the mini fails because the 1Password agent has no identities, don't loop: report it once as needs_input. VM SSH uses a dedicated key, not the 1Password agent; use a VM only after its Xcode license and first-launch checks pass and the smoke run recorded in its [host guide](../../../docs/engineering/ui-test-vm-hosts.md) has passed. The VM service must already be detached from any disposable app/agent session before use, and the VM's own lock must be available.
- **VM display preflight:** check `pmset -g assertions` in the guest for `PreventUserIdleDisplaySleep 1` and verify the console with the fail-closed check in the [host guide](../../../docs/engineering/ui-test-vm-hosts.md). Auto-login does not clear a previously locked console; XCUITest can launch the app but fail to foreground it as `Running Background`. `gui-lock run` also refuses the lease with `VM console locked` when its VirtualMac console is locked or unavailable.

## Pipeline

1. **Build on the dev Mac** (counts toward the 3-native-build limit, `-jobs 4`, isolated DerivedData):
   ```sh
   source "$HOME/.shell/exports-core.sh"
   # Run the clean-tree check before build-for-testing.
   test -z "$(git status --porcelain --untracked-files=all)" || { echo "Working tree not clean"; exit 1; }
   xcodebuild build-for-testing -project WaveWrangler.xcodeproj -scheme WaveWranglerUITests \
     -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData-ui -jobs 4
   ```
2. **Copy to the chosen GUI host** (source `"$HOME/.shell/exports.sh"` for GitHub fetches and SSH to the mini; VM aliases themselves use a dedicated key):
   ```sh
   PRODUCTS=.build/DerivedData-ui/Build/Products
   COMMIT=$(git rev-parse HEAD); SHA=${COMMIT:0:12}
   git fetch origin
   git branch -r --contains "$COMMIT" | grep -q 'origin/' ||
     { echo "Commit $COMMIT is not pushed"; exit 1; }
   find "$PRODUCTS" -maxdepth 1 -name 'WaveWranglerUITests_*.xctestrun' -print -quit |
     grep -q 'WaveWranglerUITests' ||
     { echo "Missing WaveWranglerUITests xctestrun"; exit 1; }
   codesign --verify --deep "$PRODUCTS/Debug/WaveWrangler.app"
   codesign --verify --deep "$PRODUCTS/Debug/WaveWranglerUITests-Runner.app"

   GUI_HOST=brandonmartinez@192.168.18.8 # for a VM, use ww-ui-1 or ww-ui-2
   LANE=your-lane
   REMOTE_HOME=$(ssh "$GUI_HOST" 'printf %s "$HOME"')
   TS=$(date +%Y%m%dT%H%M%S)
   TMP="$REMOTE_HOME/ww-uitest-runs/.tmp-$LANE-$SHA-$TS"
   RUN="$REMOTE_HOME/ww-uitest-runs/$LANE-$SHA-$TS"
   ssh "$GUI_HOST" "test ! -e '$TMP' && test ! -e '$RUN' && mkdir -p '$TMP/Products'"
   rsync -a "$PRODUCTS/" "$GUI_HOST:$TMP/Products/"
   CHANGES=$(rsync -a -c --dry-run --itemize-changes "$PRODUCTS/" "$GUI_HOST:$TMP/Products/")
   test -z "$CHANGES" || { printf '%s\n' "$CHANGES"; exit 1; }
   ssh "$GUI_HOST" "mv '$TMP' '$RUN'"
   ```
3. **Run one command under a lease on the selected host**, not on the
   development Mac. Keep `RUN`, `LANE`, `SHA`, and `GUI_HOST` from step 2:
   ```sh
   PR=123
   TEST_CLASS=YourUITestClass
   printf -v REMOTE_ARGS ' %q' "$RUN" "$LANE" "$SHA" "$PR" "$TEST_CLASS"
   ssh "$GUI_HOST" "bash -s --$REMOTE_ARGS" <<'REMOTE'
   set -euo pipefail
   RUN=$1; LANE=$2; SHA=$3; PR=$4; TEST_CLASS=$5
   ~/ww-uitest-runs/gui-lock status
   ~/ww-uitest-runs/gui-lock run \
     --lane "$LANE" --class pr --pr "$PR" --sha "$SHA" --dir "$RUN" \
     --result "$RUN/result.xcresult" --lease-minutes 30 --queue-timeout 3600 -- \
     xcodebuild test-without-building \
       -xctestrun "$RUN"/Products/WaveWranglerUITests_*.xctestrun \
       -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
       -only-testing:"WaveWranglerUITests/$TEST_CLASS" \
       -resultBundlePath "$RUN/result.xcresult"
   REMOTE
   ```
   The helper renews the lease only while the wrapped PID is alive and its output log advances. It verifies the
   xcresult, restores `$RUN/restore-settings.sh` when present, kills only recorded run PIDs, and releases on
   `EXIT`, `INT`, or `TERM`. A queue timeout keeps the ticket in place and continues waiting.
4. **Copy the xcresult back** from `"$GUI_HOST:$RUN/result.xcresult/"`
   to a unique local `.xcresult` directory and analyse it here
   (`xcrun xcresulttool`).
5. **Post on the PR:** SHA, host, classes, pass/fail/skip counts, xcresult location, and any new audit finding versus the pinned waiver baseline.

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
