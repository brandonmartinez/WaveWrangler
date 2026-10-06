---
name: "gui-lock-mac-mini"
description: "Use when a WaveWrangler lane needs a GUI run (XCUITest, accessibility audit, computer-use, app launch): build on the dev Mac, run on the Mac mini under the self-serve per-host GUI lock, collect the xcresult, post results on the PR. Does NOT authorize GUI work on the user's main working Mac, and reviewers never use it."
domain: "testing, GUI hosts"
confidence: "medium"
---

# Self-serve GUI lock and the Mac mini pipeline

Learned in M1 (see `docs/planning/retrospectives/m1.md` §3 #2): a single GUI host with coordinator-relayed lock messages and remote trial-and-error UI iteration was the slowest path. From M2 each lane drives its own GUI runs through a per-host lock; the coordinator sees results only.

## Rules

- **GUI hosts:** the user's Mac mini ("Macsimus": Apple M2 Pro, 12 cores, 32 GiB, macOS 27.0.1) has standing user consent for UI, XCUITest, accessibility audits, computer-use, temporary VoiceOver and temporary display/accessibility settings (record originals, restore afterwards). **Never** take over the GUI of the user's main working Mac.
- **One GUI run per host at a time.** Every result is labelled with host and SHA. The mini is not the macOS 26 / 16 GB reference.
- **Reviewers never take the lock or run UI tests.** They review diffs, CI and the evidence the author posts (a reviewer's run collided with the regression runner in M1, #149).
- **Per-PR runs** cover only the UI test classes the PR affects. PRs that change no app UI or test code skip GUI runs.
- **Batching:** a lane may batch several of its own PRs' classes only at one SHA. Never mix unrelated PR binaries.
- **GUI timebox:** after 3 failed GUI rounds on one PR, stop and hand off to Lead (design decision or follow-up issue). No fourth round.
- **Preflight first:** `.squad/skills/kickoff-preflight` (SSH agent, Automation Mode, clean screen). If SSH to the mini fails because the 1Password agent has no identities, don't loop: report it once as needs_input.

## Pipeline

1. **Build on the dev Mac** (counts toward the 3-native-build limit, `-jobs 4`, isolated DerivedData):
   ```sh
   source "$HOME/.shell/exports-core.sh"
   xcodebuild build-for-testing -project WaveWrangler.xcodeproj -scheme WaveWranglerUITests \
     -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData-ui -jobs 4
   ```
2. **Copy to the mini** (SSH needs `source "$HOME/.shell/exports.sh"` for the 1Password agent):
   ```sh
   RUN=~/ww-uitest-runs/<lane>-<pr>-<shortsha>
   ssh brandonmartinez@<mini> "mkdir -p $RUN"
   rsync -a .build/DerivedData-ui/Build/Products/ brandonmartinez@<mini>:$RUN/Products/
   ```
3. **Acquire, run, clean up, release** on the mini:
   ```sh
   ~/ww-uitest-runs/gui-lock acquire --lane <lane> --pr <N> --sha <sha> --dir $RUN --timeout 3600
   cd $RUN && xcodebuild test-without-building -xctestrun Products/WaveWranglerUITests_*.xctestrun \
     -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
     -only-testing:WaveWranglerUITests/<Class> -resultBundlePath $RUN/result.xcresult
   pgrep -fl 'WaveWrangler.app|xctest|WaveWranglerUITests-Runner'   # kill only PIDs from $RUN
   ~/ww-uitest-runs/gui-lock release --lane <lane>
   ```
   Release even when the run fails (use a `trap`). Kill orphans by PID, never by name.
4. **Copy the xcresult back** and analyse it here (`xcrun xcresulttool`).
5. **Post on the PR:** SHA, host, classes, pass/fail/skip counts, xcresult location, and any new audit finding versus the pinned waiver baseline.

## Lock helper reference

`~/ww-uitest-runs/gui-lock` lives on each GUI host, outside the repo (live on the mini since 2026-10-06). Install the same helper before using any other GUI host.

| Command | Effect |
|---|---|
| `acquire --lane L --pr N --sha S --dir RUN_DIR [--pid P] [--timeout T]` | Atomic `mkdir .gui.lock` plus an owner file (lane, PR, SHA, dir, pid, start, host). Waiters hold FIFO tickets in `.gui.queue`, polled every 15 s; abandoned tickets drop after 4 h |
| `release --lane L` | Releases the lane's lock |
| `status` | Holder and queue |

A lock is **stale** if its pid is dead or its run dir has had no new files for 30 min; it is moved to `.gui.lock.stale-<timestamp>` and logged in `gui-lock.log`. Only the coordinator intervenes on stale locks. Full-suite shards acquire the lock on every host they use.

## Hygiene (M1 lessons)

- Close other windows; keep audited windows on the primary display (occluded or straddling windows produced false contrast findings).
- Open documents with `app.launchOnce(opening:)`, never `launch()` then `open(url)` (two app processes, #135).
- Computer-use can't commit SwiftUI text fields with `set_value`/`type_text` in the background (send one `press_key` per character) and can't open pop-up or menu-bar menus: cover those steps with XCUITest. Near open/save panels, send keystrokes one at a time and verify.
- Before blaming the product for an odd failure, check for foreign WaveWrangler processes (`pgrep`, unified log `Successfully spawned WaveWrangler[`).
