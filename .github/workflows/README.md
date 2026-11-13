# Build and test CI

[`ci.yml`](ci.yml) is **manual-only** (`workflow_dispatch`). It builds the app
with `scripts/build.sh` and runs `scripts/test.sh` on the Apple Silicon
`macos-26` image, using the newest installed stable Xcode and requiring SDK 26+.

The workflow has read-only repository permission and no persisted checkout
credentials. It does not deploy, publish releases, upload media, run UI tests,
route issues or start agents. Automatic triggers require a current user decision.

Build jobs are bounded at four. Tests include package and unhosted app coverage;
specialized passes run serially. CI uses `WW_SEGMENT_SWEEPS=0` for segment
calibration only; local defaults also run the floor and edge-silence sweeps.
Live-provider and external-media/model experiments remain separately opt-in.

See [testing](../../docs/engineering/testing.md) for scope and resource limits,
and [GUI testing](../../docs/engineering/gui-testing.md) for staged VM execution.
