# WaveWrangler engineering guide

How the native macOS app is laid out, who owns which folder, and how to build and test it. Product
scope, milestones and decisions live in [`docs/planning/`](../planning/milestone-runbook.md); this page
covers code only.

## Layout

```text
WaveWrangler.xcodeproj/           Hand-authored project (objectVersion 77, synchronized folders)
  xcshareddata/xcschemes/         WaveWrangler (build + unit tests), WaveWranglerUITests (reserved)
WaveWrangler/                     App target sources (folder is synchronized: new files are included automatically)
  App/                            Entry point and NSApplicationDelegate
  Document/                       NSDocument subclasses, store, persistence/lifecycle integration
  Library/                        Library window, shallow sidebar, collections/recent/unavailable entries
  Workspace/                      Episode workspace views
  Sources/                        Source organization UI (groups/channels/epochs, primaries/backups, relink)
  Commands/                       Main menu and commands
  Settings/                       Settings window
  Support/                        Small shared helpers (e.g. declared type identifiers)
  Info.plist                      Document types and exported UTIs (merged with generated keys)
  WaveWrangler.entitlements       App Sandbox entitlements
WaveWranglerTests/                Unhosted unit tests (Swift Testing); never launch the app
WaveWranglerUITests/              Placeholder; UI tests are not run (GUI launch not yet permitted)
Packages/WaveWranglerKit/         Local Swift package linked by the app
  Sources/WWCore/                 Domain model, logical IDs, schema versions, pure validated operations
  Sources/WWPersistence/          Canonical document formats, envelope coder (publication/recovery later)
  Sources/WWSources/              Device-local source access/availability model (stub)
  Tests/WW*Tests/                 Swift Testing suites per module
scripts/build.sh, scripts/test.sh Established build/test commands (CI runs the same scripts)
.github/workflows/ci.yml          Ordinary build/test CI
```

Because app folders are `PBXFileSystemSynchronizedRootGroup`s, adding/removing files under
`WaveWrangler/`, `WaveWranglerTests/` or `WaveWranglerUITests/` does **not** edit `project.pbxproj`.
Only touch the project file for genuine target/build-setting changes, and coordinate those through the
Mac owner to avoid parallel pbxproj conflicts. Non-source files placed in `WaveWrangler/` are copied as
resources unless listed in the target's membership exceptions (as `Info.plist` is).

## Module and folder ownership

Parallel sessions work on disjoint folders. Cross-folder changes go through the owning lane.

| Area | Owner | Notes |
| --- | --- | --- |
| `App/`, project/targets, `Support/`, `WWCore` domain model, this guide | Mac (app foundation) | Schema changes require a schema bump + migration plan. |
| `Document/`, `WWPersistence` | Persistence owner | Publication, prior checkpoint, recovery, migration, autosave policy, newer-format refusal. |
| `Library/`, `Workspace/`, `Commands/`, `Settings/` | Library UI owner | Keyboard/VoiceOver/visible focus are part of done, not polish. |
| `Sources/`, `WWSources` | Sources owner | Access records, bookmarks, availability/download states, relink. |
| `.github/workflows/ci.yml`, `scripts/` | Mac (app foundation) | Keep scripts working for every lane. |

Pure domain logic belongs in the package (testable without the app); the app target holds AppKit/SwiftUI
integration. `WWPersistence` and `WWSources` depend on `WWCore`; nothing depends on the app.

## Selected M1 contracts (implemented behind swappable seams)

- **App shell:** AppKit `NSApplication` + `NSDocumentController` with `NSDocument` subclasses hosting
  SwiftUI views (`NSHostingController`). No storyboard and no SwiftUI `DocumentGroup`.
- **Portable show document** (`.wwshow`, UTI `com.brandonmartinez.wavewrangler.show`): one canonical
  JSON value, `ShowDocumentModel` — show, all episodes, recorder groups/epochs, logical source records,
  speakers and per-episode assignments, edit-history skeleton.
- **Canonical library document** (`.wwlibrary`, UTI `com.brandonmartinez.wavewrangler.library`):
  `LibraryModel` — entries (logical show refs, aliases, last-known revision, unavailable records),
  collections/order and recents. It is user work, so it is a canonical document that may live in a
  user-chosen (including cloud) folder, *not* only in Application Support. The UTI is exported now;
  no NSDocument class or location UI exists yet (library UI/persistence owners).
- **Device-local access records** (`WWSources.SourceAccessRecord`): logical source ID → bookmark,
  location hint and independent access/presence/residency/transfer/identity observations. Never
  written into canonical documents. Storage location is decided by the sources owner.
- **Derived index/cache:** rebuildable and outside canonical data (not implemented yet).
- **Envelope** (`WWPersistence.JSONEnvelopeCoder`, behind `CanonicalDocumentCoding`):
  `{checksum, format, payload, revision, schemaVersion}` with sorted keys. Reads refuse, in order:
  malformed header, wrong format, **unknown-newer schema (before the payload is decoded)**, unsupported
  older schema, invalid revision, undecodable payload, checksum mismatch, content the model would
  silently drop, and semantic validation issues. The checksum is SHA-256 over the canonical payload
  encoding — integrity bookkeeping, not authenticity. Timestamps are ISO-8601 UTC with exactly three
  fractional digits (integer-millisecond rounding keeps decode → encode byte-stable).

The current `ShowDocument` uses stock NSDocument save/autosave-in-place. That is a foundation
placeholder, **not** the hardened publication/recovery/autosave-policy contract (WW-005/006/009);
the persistence owner replaces it.

## Build and test

Prerequisites: Xcode with the macOS 26+ SDK (local: Xcode 27; CI: newest stable Xcode 26.x on
`macos-26`). The package uses `swift-tools-version: 6.2` so both toolchains work — do not raise it
without checking the CI image.

```sh
scripts/build.sh            # xcodebuild build, Debug, ad-hoc signed, -jobs 4, DerivedData in .build/
scripts/build.sh Release
scripts/test.sh             # swift test (package, --jobs 4) then xcodebuild test -only-testing:WaveWranglerTests
scripts/test.sh --package-only
scripts/test.sh --ui        # reserved: exits 2 until GUI launch/UI tests are permitted
```

Environment overrides: `WW_JOBS` (default 4) and `WW_DERIVED_DATA` (default `.build/DerivedData`).
All outputs live under the gitignored `.build/` inside your worktree.

Settings: macOS 26.0 deployment target, arm64 only, Swift 6 language mode with complete strict
concurrency, App Sandbox + user-selected read-write files + app/document-scoped bookmarks, hardened
runtime, ad-hoc signing (`CODE_SIGN_IDENTITY=-`, no team). There is no network entitlement.

`WaveWranglerTests` is an **unhosted** bundle: it links the package products and reads the app's
`Info.plist`/entitlements from the source tree, so running it never launches the app.

### Concurrency limits

- At most one `xcodebuild` per session and at most three concurrently on the host, each `-jobs 4`
  with its own DerivedData (the scripts do this).
- Run test suites serially per lane (`scripts/test.sh` disables parallel xcodebuild testing).
- Don't run UI tests or launch the app unless the coordinator has relayed explicit permission.

### Local host prerequisite

`xcodebuild` requires Xcode's first-launch system components. If it fails with "failed to load a
required plug-in … run `xcodebuild -runFirstLaunch`" (check with `xcodebuild -checkFirstLaunchStatus`),
someone with admin rights must run `sudo xcodebuild -runFirstLaunch`. Agents must not do this without
explicit user permission. `scripts/test.sh --package-only` works without it.

## Conventions

- **Originals are immutable.** No code path renames, moves, deletes, overwrites or writes into a
  referenced source, and nothing silently substitutes a same-named file.
- **Logical IDs are identity.** Paths, filenames and bookmarks are location/permission hints only.
- **Unknown is a state.** Use `Knowledge<T>.unknown` / explicit `unknown` enum cases; never a sentinel.
  Unknown, denied, missing, changed, unverified, residency and transfer states stay distinct.
- **Metadata-only means zero content access.** OFF/metadata-only paths make no content, hash, header,
  preview, decode or download requests. M1 has no decode or audio analysis at all.
- **Refuse, don't repair.** Readers refuse unknown-newer, damaged or inconsistent documents and leave
  the file unchanged; never downsave.
- **Honest state.** Never show "saved" without coherent disk truth; dirty state comes from the undo
  manager/change count.
- **Pure operations.** Domain changes are `WWCore` functions that return a new value or throw a
  `DomainError` without partial mutation; the app registers undo with a user-facing action name.
- **Tests use synthetic fixtures only**, generated in memory or in temporary directories. Never read
  user recordings or sample folders.
- **Accessibility is part of done:** keyboard reachability, VoiceOver labels, visible focus and
  non-drag alternatives for every core workflow.
