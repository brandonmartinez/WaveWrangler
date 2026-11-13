# Testing

Choose the smallest layer that demonstrates the changed behavior. Tests use
generated fixtures by default; neither test discovery nor a historical record
authorizes models, user media, live providers or frozen holdout reruns.

## Layers

| Layer | What it establishes | Execution |
| --- | --- | --- |
| Swift package | Domain/coding/geometry, source admission, pure DSP/policy, job races and bounded synthetic processing | `scripts/test.sh --package-only` or a focused `swift test` |
| Unhosted app tests | App adapter/value behavior without launching the editor | `scripts/test.sh` adds `WaveWranglerTests` |
| Hosted app tests | Real AppKit/SwiftUI ownership, Undo, native effects and rendering integration | Build-for-testing, stage, then leased VM `test-without-building` |
| UI tests | Actual controls, keyboard/focus, drag/drop, accessibility and lifecycle | Explicit test plan/profile on a ready leased VM |
| Opt-in experiments | Model-backed, live-provider, external-media, performance or qualification evidence | Separate scope, prerequisites and authorization |

Unhosted tests do not become hosted just because they import app adapter files.
When adding an app dependency, check the synchronized group's target membership
exceptions. A successful package run does not compile every hosted/UI target.
Build-for-testing is a useful compilation check but is not runtime evidence.

## Established commands

From the repository root:

```sh
umask 022
WW_JOBS=2 WW_TEST_WORKERS=2 \
  WW_DERIVED_DATA="$PWD/.build/TestDerivedData" scripts/test.sh
```

The script first checks UI-plan inventory and the generated native timestamp
bridge, then runs package tests, serialized estimator/segment/heavy passes and
calibration checks, followed by unhosted Xcode tests. `--package-only` omits
only the final Xcode test step; it is not a shortcut around heavy package checks.

For a focused package regression:

```sh
swift test --package-path Packages/WaveWranglerKit \
  --scratch-path .build/swiftpm --jobs 2 --filter '<Suite>/<test>'
```

Use the real suite/function selector and the opt-in environment required by
that suite. Prefer combining related selectors in one runner rather than
launching overlapping builds. The wrapper's specialized passes matter:
`WW_ESTIMATOR_TESTS`, `WW_SEGMENT_TESTS`, `WW_PIPELINE_HEAVY_TESTS` and
`WW_TIMING_TESTS` are not blanket permission to run unrelated experiments.
Inspect `scripts/test.sh` for the maintained selectors and pass order.

For app adapters, use scheme `WaveWrangler`,
`-only-testing:WaveWranglerTests`, `-parallel-testing-enabled NO`, an arm64 macOS
destination and a separate `-derivedDataPath`. For hosted/UI runtime work,
follow the [GUI build/stage/run procedure](gui-testing.md) instead of running
`xcodebuild test` on the desktop.

## Resource and isolation limits

- `WW_JOBS` defaults to four; `WW_TEST_WORKERS` defaults to four and controls
  Swift Testing through `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`.
  Coordinate the total across concurrent builds/suites, not just each process.
- Estimator concurrency defaults to two, maximum four. Values above two require
  a matching `WW_ESTIMATOR_CONCURRENCY_GRANT`; this is a resource agreement, not
  qualification permission. Segment calibration uses its bounded harness.
- Keep specialized passes serialized. `WW_SEGMENT_SWEEPS` defaults to one
  locally and zero in CI; the latter still runs gated committed calibration.
- Use one active Xcode build per session. Keep aggregate host usage bounded;
  the established host ceiling is three builds at four jobs each, not a goal
  to fill whenever another task is running.
- Test DerivedData must not replace the build currently being edited or run.
  Separate concurrent SwiftPM scratch roots as well.
- Tests expect `umask 022`, including 0644 fixture files. Create private logs
  separately with mode 0600; do not make the entire test process use umask 077.

## Regression design

Add a few focused cases that fail without the change. Check meaningful output,
refusal and cancellation rather than restating constants or private helpers.
Use temporary directories and generated PCM; keep media grants explicit even
in tests.

Persistence changes need independently specified envelopes/migrations and
unknown-newer refusal, not only a same-code roundtrip. Audible edits need exact
frames/channel sums, not only visible markers. Async changes need late-result,
revocation and cancellation/permit-release coverage. Native-state changes need
actual Save/Undo/Redo/close barriers and multiple-window ownership.

Capture small scalar/optional leaves before Swift Testing assertions on heavy
document/runtime models. Direct member assertions can recursively attach a
huge runtime graph to xcresults. Keep diagnostic artifacts bounded and preserve
the first meaningful failure.

UI changes require native interaction evidence where relevant: keyboard and
non-drag alternatives, focus routing, readable accessibility state, document
updates and Undo. Keep accessibility identifiers on actual controls; an outer
SwiftUI identifier can propagate onto native outline/empty-state elements.
Use coordinate `click(forDuration:thenDragTo:)` for macOS XCUI drags.

## Plans, evidence and CI

`scripts/test.sh --ui` selects **PoC**, not the complete UI bundle.
Focused selectors implicitly choose Regression unless a profile is explicit.
Profiles are `poc`, `regression`, `accessibility` and `performance`.
Xcode intersects selectors with the built plan, so inspect actual executed
identities and nonzero counts. Plan inventory, not a hard-coded count here,
defines coverage.

Ordinary hosted/UI execution requires a ready, unlocked, exclusively leased
[VM](ui-test-vm-hosts.md). No desktop/Mac mini fallback is authorized by VM
failure. Deferred accessibility, ignored opt-ins and environment-invalid
execution are not passes. Apply [quarantine](gui-flake-quarantine.md) narrowly.

CI is [manual-only](../../.github/workflows/README.md), running build plus
package/unhosted tests on macOS 26. It does not provide GUI or release clearance.

Historical freezes and maintained source pins live in
[test support](../../test-support/README.md). Preserve frozen bytes, seeds,
gates and failures. A `currentTrees` refresh is source maintenance, not a new
holdout pass; do not bypass changed-tree refusal or describe calibration as
unseen qualification.
