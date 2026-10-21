# GUI test pipeline

Use the [macOS VM hosts](ui-test-vm-hosts.md), normally `ww-ui-1` or `ww-ui-2`.
The host guide owns readiness checks and physical-host exceptions. The user's
desktop and Mac mini are not fallback test hosts.

## Prepare the build

Load `source "$HOME/.shell/exports-core.sh"` before each local shell command.
Build on the development Mac, not in the guest, with isolated DerivedData and
at most four build workers. Keep the editing app's bundle separate.

```sh
xcodebuild build-for-testing \
  -project WaveWrangler.xcodeproj -scheme WaveWranglerUITests \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData-ui -jobs 4 \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

swift build --package-path Packages/WaveWranglerKit \
  --scratch-path .build/swiftpm --jobs 4 --product wwpersist-probe
```

Record the exact commit and whether the working tree is dirty. A dirty-tree
run is development feedback, not exact-commit qualification. Do not commit or
push solely to obtain a test label without user authorization.

Copy the signed Products and the `wwpersist-probe` executable to a unique
per-run guest directory under `~/ww-uitest-runs/`, staging in a temporary
directory and renaming it only after transfer verification. Do not overwrite
another run. Check `rsync -c` equality and verify the app and test runner
signatures with `codesign --verify --deep`. Confirm that the `.xctestrun`
contains `WaveWranglerUITests`.

Only synthetic fixtures belong in the VMs. Never mount or copy user
recordings, transcripts, or model weights without separate approval.

## Run and collect

Recheck the guest's unlocked console, display-awake assertion, Xcode
first-launch status, and `~/ww-uitest-runs/gui-lock status` before dispatch.
Use the existing lease helper from `scripts/gui-lock`; do not delete its
guard or another run's ticket.

On the chosen guest, set `RUN` to the absolute per-run directory, `SHA` to
the recorded commit, and `TEST_CLASS` to the affected class:

```sh
test -x "$RUN/wwpersist-probe"
TEST_RUNNER_WW_PROBE="$RUN/wwpersist-probe" \
  ~/ww-uitest-runs/gui-lock run \
    --lane refinement --class pr --sha "$SHA" --dir "$RUN" \
    --result "$RUN/result.xcresult" --lease-minutes 30 --queue-timeout 3600 -- \
    xcodebuild test-without-building \
      -xctestrun "$RUN"/Products/WaveWranglerUITests_*.xctestrun \
      -destination 'platform=macOS,arch=arm64' \
      -parallel-testing-enabled NO \
      -only-testing:"WaveWranglerUITests/$TEST_CLASS" \
      -resultBundlePath "$RUN/result.xcresult"
```

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
