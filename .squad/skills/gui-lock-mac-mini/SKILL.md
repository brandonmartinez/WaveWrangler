---
name: "gui-lock-mac-mini"
description: "Use when a WaveWrangler lane needs a GUI run, including XCUITest, an accessibility audit, computer-use, or an app launch. Build on the dev Mac, then use the Mac mini lease helper for exactly one run, collect the xcresult, and post the evidence on the PR. Does NOT authorize GUI work on the user's main working Mac, manual lock holding between runs, or GUI work by reviewers."
---

# Self-serve GUI lock and the Mac mini pipeline

Learned in M1 (see `docs/planning/retrospectives/m1.md` §3 #2): a single GUI host with coordinator-relayed lock messages and remote trial-and-error UI iteration was the slowest path. From M2 each lane drives its own GUI runs through a per-host lock; the coordinator sees results only.

## Rules

- **GUI hosts:** the user's Mac mini ("Macsimus": Apple M2 Pro, 12 cores, 32 GiB, macOS 27.0.1) is the default and only standing GUI host. It has user consent for UI, XCUITest, accessibility audits, computer-use, temporary VoiceOver and temporary display/accessibility settings (record originals, restore afterwards). The user's main working Mac is a GUI host only inside an explicitly user-granted away window (its own lock; never computer-use or VoiceOver; stop on user input). Reach the mini by IP (`ssh -o BatchMode=yes brandonmartinez@192.168.18.8`); never edit `known_hosts`.
- **Products come from a committed, pushed SHA only.** Never label a run with a working-tree name. Before use, verify that the `.xctestrun` names `WaveWranglerUITests`, run `codesign --verify --deep` on the app and the Runner, and check `rsync -c` checksum equality. Copy atomically into a per-run unique folder (`rsync` to `~/ww-uitest-runs/.tmp-<lane>-<sha>-<ts>`, then `mv` to `<lane>-<sha>-<ts>`), and never reuse or overwrite another run's folder. A run that breaks these rules is environment-invalid (2026-10-07: `pr219-final-r1`), not a pass or a product failure.
- **Performance strata** can't be split, so each `ResponsivenessUITests` method gets its own `perf` ticket of up to 45 minutes, after ≥60 s idle and with the pre-run load below 6.
- **One GUI run per lease.** `scripts/gui-lock run` owns one `test-without-building` invocation and releases in a trap. Never hold the GUI while analysing, rebuilding, or preparing another round.
- **Check status before polling lanes.** `gui-lock status` shows the holder, lease age, priority queue, ticket ages and estimated wait.
- **Priority:** `required` (required path / exit gate), then `pr`, then `full` and `perf`; FIFO within a class.
- Every result is labelled with host and SHA. The mini is not the macOS 26 / 16 GB reference.
- **Reviewers never take the lock or run UI tests.** They review diffs, CI and the evidence the author posts (a reviewer's run collided with the regression runner in M1, #149).
- **Per-PR runs** cover only the UI test classes the PR affects. PRs that change no app UI or test code skip GUI runs.
- **Batching:** a lane may batch several of its own PRs' classes only at one SHA. Never mix unrelated PR binaries.
- **GUI timebox:** after 3 failed counted GUI rounds on one PR, stop and hand off to Lead (design decision or follow-up issue). There is no fourth counted round unless a recorded Lead decision (on the PR and in `decisions.md`) restarts the count. Rounds that never ran (lock stolen, quiet-gate rejection, released before `xcodebuild`) or were environment-invalid don't count.
- **Preflight first:** `.squad/skills/kickoff-preflight` (SSH agent, Automation Mode, clean screen). If SSH to the mini fails because the 1Password agent has no identities, don't loop: report it once as needs_input.

## Pipeline

1. **Build on the dev Mac** (counts toward the 3-native-build limit, `-jobs 4`, isolated DerivedData):
   ```sh
   source "$HOME/.shell/exports-core.sh"
   # Run the clean-tree check before build-for-testing.
   test -z "$(git status --porcelain --untracked-files=all)" || { echo "Working tree not clean"; exit 1; }
   xcodebuild build-for-testing -project WaveWrangler.xcodeproj -scheme WaveWranglerUITests \
     -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData-ui -jobs 4
   ```
2. **Copy to the mini** (SSH needs `source "$HOME/.shell/exports.sh"` for the 1Password agent):
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

   TS=$(date +%Y%m%dT%H%M%S)
   TMP=~/ww-uitest-runs/.tmp-<lane>-"$SHA"-"$TS"
   RUN=~/ww-uitest-runs/<lane>-"$SHA"-"$TS"
   MINI=brandonmartinez@<mini>
   ssh "$MINI" "test ! -e '$TMP' && test ! -e '$RUN' && mkdir -p '$TMP/Products'"
   rsync -a "$PRODUCTS/" "$MINI:$TMP/Products/"
   CHANGES=$(rsync -a -c --dry-run --itemize-changes "$PRODUCTS/" "$MINI:$TMP/Products/")
   test -z "$CHANGES" || { printf '%s\n' "$CHANGES"; exit 1; }
   ssh "$MINI" "mv '$TMP' '$RUN'"
   ```
3. **Run one command under a lease** on the mini:
   ```sh
   ~/ww-uitest-runs/gui-lock status
   ~/ww-uitest-runs/gui-lock run \
     --lane <lane> --class pr --pr <N> --sha <sha> --dir "$RUN" \
     --result "$RUN/result.xcresult" --lease-minutes 30 --queue-timeout 3600 -- \
     xcodebuild test-without-building \
       -xctestrun "$RUN"/Products/WaveWranglerUITests_*.xctestrun \
       -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
       -only-testing:WaveWranglerUITests/<Class> \
       -resultBundlePath "$RUN/result.xcresult"
   ```
   The helper renews the lease only while the wrapped PID is alive and its output log advances. It verifies the
   xcresult, restores `$RUN/restore-settings.sh` when present, kills only recorded run PIDs, and releases on
   `EXIT`, `INT`, or `TERM`. A queue timeout keeps the ticket in place and continues waiting.
4. **Copy the xcresult back** and analyse it here (`xcrun xcresulttool`).
5. **Post on the PR:** SHA, host, classes, pass/fail/skip counts, xcresult location, and any new audit finding versus the pinned waiver baseline.

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
