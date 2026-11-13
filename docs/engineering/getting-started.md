# Getting started

## Requirements

- Apple Silicon (`arm64`), macOS 26 or newer.
- Full Xcode with macOS SDK 26 or newer; select it as the active developer
  directory. Command Line Tools alone are insufficient for the app targets.
- Swift tools 6.2 or newer. `Package.swift` intentionally remains compatible
  with Xcode 26.x CI while local development may use a newer Xcode.
- Xcode license accepted and first-launch components installed.

Check `xcodebuild -version`, `xcrun --sdk macosx --show-sdk-version`,
`swift --version`, and `xcodebuild -checkFirstLaunchStatus`.
If system components require administrator setup, stop and have an authorized
operator complete it. Never run the build or installer with sudo.

Open `WaveWrangler.xcodeproj`. The app uses Swift 6 language mode, complete
strict concurrency, the macOS 26 deployment target and arm64 destinations.
App folders use synchronized Xcode groups: adding an ordinary source file does
not require editing `project.pbxproj`. Target membership exceptions, build
settings and new targets do require deliberate project changes.

## Build without replacing the editing app

From the repository root:

```sh
WW_JOBS=2 WW_DERIVED_DATA="$PWD/.build/DevelopmentDerivedData" scripts/build.sh Debug
```

Use `Release` for optimized app builds. The script defaults to four jobs and
`.build/DerivedData`; choose an explicit output directory when another build
or the editing app is using that default. Keep test builds in a different
DerivedData directory, and do not let simultaneous SwiftPM builds share a
scratch directory.

The script prints the completed bundle path, marketing version and build
number. `scripts/build_number.py` generates a monotonic derived header for
`CFBundleVersion`; a build does not edit a tracked version file or Git state.
The running app reads its identity from its own bundle. When asked to build
and launch, verify that identity rather than assuming a different installed
copy was replaced.

Local builds use ad-hoc signing (`CODE_SIGN_IDENTITY=-`, manual signing, no
team), App Sandbox and hardened runtime. The entitlements permit user-selected
files and scoped bookmarks. Outgoing network supports explicit verified model
downloads; it does not imply audio/transcript upload or telemetry.

## Verified local install

Quit the app yourself, then run:

```sh
scripts/install-local.sh Debug
```

The default destination is `/Applications`, with build output isolated in
`.build/LocalInstallDerivedData`. If the destination is not writable, choose
an existing user-owned directory:

```sh
WW_INSTALL_DIR="$HOME/Applications" scripts/install-local.sh Debug
```

The installer refuses a running app, symlink destination or different bundle
identity. It serializes installation, verifies signatures and copied bytes,
and rolls back a failed replacement. It never quits or launches the app and
never elevates privileges. After an uncatchable interruption, inspect the
specific `.WaveWrangler.install.*` backup before recovery; remove an empty
installation lock only after confirming no installer owns it.

## First checks

```sh
umask 022
WW_JOBS=2 WW_TEST_WORKERS=2 \
  WW_DERIVED_DATA="$PWD/.build/TestDerivedData" scripts/test.sh
```

Use `--package-only` to omit the unhosted Xcode test step; it still runs the
script's specialized package/native checks. See [testing](testing.md) for
focused selectors and resource budgets.

Build-for-testing is safe preparation without launching the app. Hosted and
UI execution belong on a ready, leased VM through the
[GUI pipeline](gui-testing.md), not on the development desktop. Installation
or build success is not permission for media access or an experimental rerun.
