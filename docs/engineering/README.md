# WaveWrangler engineering guide

How the native macOS app is laid out, who owns which folder, and how to build and test it. Product
scope, milestones and decisions live in [`docs/planning/`](../planning/milestone-runbook.md); this page
covers code only.

## Layout

```text
WaveWrangler.xcodeproj/           Hand-authored project (objectVersion 77, synchronized folders)
  xcshareddata/xcschemes/         WaveWrangler (build + unit tests), WaveWranglerUITests (XCUITests; GUI)
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
WaveWranglerUITests/              XCUITests + accessibility audits (launch the app; GUI lock required)
Packages/WaveWranglerKit/         Local Swift package linked by the app
  Sources/WWCore/                 Domain model, logical IDs, schema versions, pure validated operations
  Sources/WWPersistence/          Formats/coder, publication protocol, recovery store, migration, autosave policy, library store
  Sources/WWPersistenceProbe/     `wwpersist-probe` headless CLI for multi-process/provider trials (synthetic files only)
  Sources/WWSources/              Source references: read-only gateway, access records, availability, import, relink
  Sources/WWOrganizer/            Library/workspace presentation: wording catalogs, preference keys,
                                  collection/combine operations, library session, sidebar models, menu shortcut register
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
  `LibraryModel` — entries (logical show refs, aliases, last-known publication, unavailable records),
  collections/order and recents. It is user work, so it is a canonical document that may live in a
  user-chosen (including cloud) folder, *not* only in Application Support. `WWPersistence.LibraryStore`
  (app adapters `LibraryDocumentStore` / `LibraryLocationController`) publishes it with the same protocol
  as shows, keeps its own prior checkpoints, defaults to the app container and can move to a chosen
  folder (copy → verify → switch; the old copy is kept). "Use That Library" combines both libraries with
  nothing dropped; same-named collections that differ get "(from this Mac)", "(from this Mac 2)", …
  While the folder is unreachable or needs permission (L2/L3), organizing edits go to a device-local
  pending-edits journal ("Edits waiting") and are applied through the base check (ST-36 combine on
  divergence) when it is reachable again; the journal is cleared only after verified publication.
  **Library identity:** schema 2 adds `LibraryModel.libraryID`; edits can't change it. "Grant Access…"
  (`LibraryStore.regrantAccess(to:)`, `LibraryLocationController.regrantAccess(to:)`) saves a new folder grant
  only when the re-selected folder holds the same library ID, then reloads and replays queued edits
  (`reload()` re-adopts after recovery or "Use Other Mac's Version"). Schema 1 libraries are read through
  `LibraryCoder` with an ID derived from their publication ID; their bytes are backed up before the first
  schema 2 publication.
- **Device-local access records** (`WWSources.DeviceAccessRecord`, keyed by `DeviceAccessKey`
  = (ShowID, SourceID), so a duplicated show never shares or overwrites the original's grants): read-only
  security-scoped bookmark, last-known path/volume hints, a metadata-only identity baseline
  (`FileSystemFingerprint`: size, creation/modification dates, persistent file identifier, volume UUID,
  extension-derived type; provisional until the user confirms; dates compare within 1 ms because
  iCloud rematerialization shifts them by ~1e-7 s, other fields compare exactly) and the latest
  observation. Stored as a
  versioned JSON file in Application Support (`FileDeviceAccessStore`); never written into canonical
  documents. Paths, names and bookmarks are hints, never identity.
- **Source gateway** (`WWSources.SourceIO`): the only path to referenced originals. It exposes metadata
  reads, directory listing, read-only bookmark create/resolve, scope start/stop and an iCloud download
  request — no read/hash/preview/decode/write/move/delete API exists. `SecurityScopeLedger` pairs every
  scope start with a stop (`withScopedAccess`). A source-scan test forbids content-capable or mutating
  APIs elsewhere in WWSources.
- **Source engine:** `SourceImporter` (metadata-only, UTType-by-extension audio filter, provisional
  group/epoch/speaker suggestions), `SourceAvailabilityEvaluator` (independent location / access /
  residency / transfer / identity dimensions; denied ≠ missing; stale bookmarks refreshed only when
  identity evidence matches), `RelinkEvaluator` (explicit, user-chosen candidates; confirmation for
  anything but an exact match), `SourceTransferController` (download/progress/cancel/retry/offline) and
  the `@MainActor @Observable` `SourceAvailabilityMonitor` for the Sources UI. The availability setting
  is injected as `SourceAvailabilitySetting(downloadSourcesAutomatically:)` from the app preference.
- **Derived index/cache:** `LibraryIndex` in Caches, rebuilt whenever missing/stale/damaged; never authoritative.
- **Envelope** (`WWPersistence.JSONEnvelopeCoder`, behind `CanonicalDocumentCoding`):
  `{checksum, format, payload, publicationID, revision, schemaVersion}` with sorted keys. Only
  `{format, schemaVersion}` is frozen across versions and is decoded first. Reads refuse, in order:
  malformed version header, wrong format, **unknown-newer schema (before any version-specific field or
  the payload is decoded)**, unsupported older schema, malformed publication header, invalid revision,
  undecodable payload, checksum mismatch, content the model would silently drop, and semantic
  validation issues.
- **Publication identity:** every write gets a fresh `publicationID`. `PublicationStamp`
  `{revision, publicationID, checksum}` identifies what is on disk, and `LibraryShowEntry` records it as
  `lastKnownPublication`. `revision` is **only an ordering hint**: two devices or a restored Version can
  publish the same revision number with different content. Conflict detection compares publication ID
  and checksum.
- **Show identity and copies:** File ▸ Duplicate gives the copy a new `ShowID` (show-scoped episode,
  source and speaker IDs are kept). A Finder/provider copy of a `.wwshow` file keeps the **same**
  `ShowID` as the original. The library lane must surface that collision to the user (for example by
  offering "treat as a copy" with a new ID); it must never silently drop, merge or overwrite either
  document. The checksum is SHA-256 over the canonical payload
  encoding — integrity bookkeeping, not authenticity. Timestamps are ISO-8601 UTC with exactly three
  fractional digits (integer-millisecond rounding keeps decode → encode byte-stable).

### Persistence (WW-009 C2–C6)

- **Publication** (`DocumentPublisher`): P1 candidate validated → P2 validated prior retained in the
  device-local `RecoveryStore` → P3 coordinated base check (exact bytes; mismatch = conflict, nothing
  overwritten, candidate preserved) → stage + flush + verify → P4 replace → P5/P6 independent read-back →
  P7 library acknowledgement → derived index. Failures keep the prior revision and dirty state; a
  post-publication doubt is `acknowledgementUncertain`, never "saved". `ShowDocument` runs the same order
  inside its `writeSafely` override around stock `super.writeSafely` (`AlreadyCoordinated`; P4 is inside
  AppKit). Only Save, Save As and autosave-in-place adopt the new publication.
- **Recovery store** (Application Support, device-local, keyed by logical ID so it survives moves): last
  three validated priors, C2b unpublished edit checkpoints, conflict candidates, migration backups.
  It gives no cross-device recovery.
- **Open:** unknown-newer refuses (never written); damaged files offer a whole validated checkpoint as
  a new untitled copy; migrations preserve the original plus a non-overwriting backup and publish only
  after independent expectations pass.
- **Autosave** (`WWAutosaveEnabled`, `WWAutosaveDelaySeconds` ∈ {1, 2, 5, 10, 30}): the gate is checked
  at `autosavesInPlace`, `scheduleAutosaving()` and every `autosave(withImplicitCancellability:)`.
  OFF schedules nothing, cancels queued automatic work (never a success-shaped `nil`), stays dirty and
  uses AppKit's Save / Don't Save / Cancel review. ON publishes after the quiet delay; if that cannot be
  verified within 1.5 s of the last edit, a C2b edit checkpoint is written at quiescence (0.5 s).
- **Evidence harness** (`Tests/WWPersistenceTests`): ≥100 injected interruptions per boundary
  (P1–P7, L1–L6, M1–M3) plus real `_exit` process kills and two-process conflicts via `wwpersist-probe`.
  Results are appended to `Packages/WaveWranglerKit/.build/persistence-evidence.log`.

## Build and test

Prerequisites: Xcode with the macOS 26+ SDK (local: Xcode 27; CI: newest stable Xcode 26.x on
`macos-26`). The package uses `swift-tools-version: 6.2` so both toolchains work — do not raise it
without checking the CI image.

```sh
scripts/build.sh            # xcodebuild build, Debug, ad-hoc signed, -jobs 4, DerivedData in .build/
scripts/build.sh Release
scripts/test.sh             # swift test (package, --jobs 4), serialized timing pass, then xcodebuild test -only-testing:WaveWranglerTests
scripts/test.sh --package-only
scripts/test.sh --ui        # XCUITests only (launches the app); needs GUI permission + the coordinator's GUI lock
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
- Don't run UI tests or launch the app without GUI permission; take the coordinator's GUI lock first
  (one agent drives the screen at a time) and release it right after.

### Local host prerequisite

`xcodebuild` requires Xcode's first-launch system components. If it fails with "failed to load a
required plug-in … run `xcodebuild -runFirstLaunch`" (check with `xcodebuild -checkFirstLaunchStatus`),
someone with admin rights must run `sudo xcodebuild -runFirstLaunch`. Agents must not do this without
explicit user permission. `scripts/test.sh --package-only` works without it.

## Preference keys

App-level `UserDefaults` keys live in `WWOrganizer.PreferenceKey`; `AppPreferences(defaults:)` reads them with
the product defaults applied, so a missing key always means the default. The Settings window writes them.

| Key | Type | Default | Read by |
| --- | --- | --- | --- |
| `WWAutosaveEnabled` | Bool | `true` (autosave ON) | Persistence (autosave policy), show save status |
| `WWDownloadSourcesAutomatically` | Bool | `true` (downloads ON) | Sources (availability/download) |
| `WWTextSizePercent` | Int 100–200, step 25 | `100` | All WaveWrangler windows (in-app text size, CMD-20) |
| `WWSettingsLastPane` | String (`general`/`sources`) | `general` | Settings window |

## UI seams between lanes

The library/workspace UI talks to other lanes only through these protocols. Keep them stable; extend
additively and update this table.

| Seam (file) | Implemented by | Contract |
| --- | --- | --- |
| `DocumentStatusProviding` (`Workspace/DocumentStatus.swift`) | `ShowDocument` via `Workspace/ShowDocumentStatus.swift` (maps `DocumentStatusModel` → `WWOrganizer.DocumentSaveState`) | Observable `saveStatus` (D1–D16 + checking/unknown/read-only). "Saved" only for persistence's verified-on-disk states. `NativeDocumentStatusObserver` remains the honest fallback for any document without a status model. |
| `DocumentStatusActionHandling` (same file) | Persistence (optional) | Handles popover/message-bar actions (Resolve…, Try Again, Save a Copy Elsewhere…, Cancel Save…). |
| `LibraryPersisting`, `LibraryLocationControlling` (`Library/LibraryServices.swift`) | `Library/PersistenceLibraryBackend.swift` over persistence's `LibraryDocumentStore` + `LibraryLocationController` | Load, then apply edits as **transforms** on the canonical value (never whole snapshots) and follow `currentLibrary`; L1–L5 (+ damaged) state, pending-edits status, ST-34 quit text, copy → verify → retire moves, “already has a library” combine, combine summaries incl. queued edits not carried. |
| `LibraryEntryObserving` (same file) | `InMemoryLibraryBackend` (per-show “as of last open” details from shows opened this run) | Device-local, rebuildable; open/locate/reveal by show identity. `InMemoryLibraryBackend` also backs UI-test fixtures. |
| `SourceCommandHandling` (`Commands/SourceCommands.swift`) | Sources UI | File › Import Sources…, Relink Source…, extra Source-menu items, and optional Edit › Delete / Move Up/Down hooks for the Sources/Speakers tables (return a title only while your table has focus). `SourceCommands.handler` defaults to a placeholder that changes nothing. |
| `AutosavePolicyConnection` (`Settings/AutosavePolicyConnection.swift`) | Persistence `AutosavePolicyController` | The Settings toggle binds to `AutosavePolicyController.shared.isEnabled` (`WWAutosaveEnabled`/`WWAutosaveDelaySeconds`); `isConnected` is true only while that controller is the source of truth. |
| `SetupSourcesContent.makeView` (`Workspace/SetupContainerView.swift`) | Sources UI | `(ShowDocumentStore, EpisodeID) -> AnyView` hosted in the Setup destination (Sources outline + Speakers table). |

Show windows: `ShowDocument` hosts `ShowWorkspaceView(store:)`; per-window state (`ShowWindowState`) is
registered for menu routing (`CommandRouter`). Edits go through `ShowDocumentStore.apply(_:coalescing:_:)`
with the user-facing undo names in `WWOrganizer.UndoActionName`.

Library ordering: `LibraryUIStore` (backed by the pure, unit-tested `WWOrganizer.LibrarySession`) loads at
launch, never writes before load / after a failed load / while read-only (L4/L5), queues show-open bookkeeping,
refreshes titles only after a coherent save (D1), and undoes only what an action changed.

UI-test launch arguments (Debug builds; synthetic data only): `-WWUITestResetPreferences YES`,
`-WWUITestLibraryFixture lib100|empty`, `-WWUITestOpenShow <name>` with `-WWUITestShowEpisodes <n>`, and
`-WWForceReduceMotion YES`.

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
