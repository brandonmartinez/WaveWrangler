# WW-008 — M1 internal platform, lifecycle, permission, privacy and rights register

**Record date:** 2026-10-04 · **Author:** Lead (register/scope) · **Informational issue owner:** Mac · **Issue:** [WW-008 (#7)](https://github.com/brandonmartinez/WaveWrangler/issues/7) · **Milestone:** [M1](https://github.com/brandonmartinez/WaveWrangler/milestone/1)
**Contracts:** [WW-009 record](ww-009-m1-contracts.md) · **Fixtures:** [WW-003 protocol](ww-003-fixture-protocol.md)

**Purpose and limit.** WW-008's M1 staged closure needs a *feasible internal* lifecycle/support/permission/privacy/rights register, explicit candidate-specific unknowns and a safe internal-use envelope. This register is that inventory and decision record. It is **not** evidence that the app behaves as described: rows marked *to evidence* close only with Mac's code/test evidence. Signed, notarized and clean-install public artifact proof belongs to [WW-041 (#39)](https://github.com/brandonmartinez/WaveWrangler/issues/39) and [WW-052 (#49)](https://github.com/brandonmartinez/WaveWrangler/issues/49).

**Labels:** **F** fact with a cited source (Apple DocC fetched 2026-10-04, repo research, or a host observation) · **D** Lead M1 decision · **U** unknown/unverified · **G** open gate.

## 1. Support direction vs claimed host

| Dimension | Accepted product direction | Actual claimed M1 host (observed 2026-10-04) | Status |
| --- | --- | --- | --- |
| OS | macOS 26+ | macOS 27.0.1 (build 26A434) | **F**. Deployment target 26 compiles, but macOS 26 runtime is **untested** (U) |
| CPU | Apple silicon only | Apple M5 Max, 18 cores, arm64 | **F** |
| Memory | 16 GB initial reference; 8 GB later | 128 GiB (137,438,953,472 bytes) | **F**. Not reference proof |
| Language | English only | English UI | **D** |
| Toolchain | — | Xcode 27.0 (27A266a), macOS SDK 27.0, Apple Swift 6.4 (swiftlang-6.4.0.34.1) | **F** |
| Intel / non-English | Deferred | — | **D**. Unsupported, with no decline claim |
| Distribution | Signed/notarized direct download first; App Store first launch deferred | Ad-hoc "Sign to Run Locally" internal builds only | **D**. Public route → WW-041/052 |

**Internal-use envelope (D):** M1 claims only "usable on this claimed host by its owner, with synthetic-tested durability and source-safety contracts". It makes no minimum-device, macOS 26 runtime, 16 GB, public-distribution or App Review claim. Deployment target **macOS 26.0** keeps the direction honest at compile level. Any API that needs a newer OS must be availability-gated and recorded here.

## 2. Native lifecycle API register

| API / mechanism | Use in M1 (C# = [WW-009 contract](ww-009-m1-contracts.md)) | Documentary basis (F) | Evidence status |
| --- | --- | --- | --- |
| `NSDocument` subclass + SwiftUI hosting | Show document lifecycle (C1) | [NSDocument](https://developer.apple.com/documentation/appkit/nsdocument) | Prior research subsets only; *to evidence* in app |
| `autosavesInPlace` | Class opt-in; it is **not** the ON/OFF switch | [autosavesInPlace](https://developer.apple.com/documentation/appkit/nsdocument/autosavesinplace) (macOS 10.7+) | *to evidence* |
| `scheduleAutosaving()`, `autosave(withImplicitCancellability:completionHandler:)` | Enabled-flag boundaries (C6) | DocC pages (macOS 10.7+) | **U** exact legal hooks; *to evidence* |
| `NSDocumentController.autosavingDelay` | Configurable cadence | [autosavingDelay](https://developer.apple.com/documentation/appkit/nsdocumentcontroller/autosavingdelay) | *to evidence*. ≈5 s at 5 s observed historically |
| `autosavingFileType` | Must stay a valid type; **never nil/empty for disablement** | [autosavingFileType](https://developer.apple.com/documentation/appkit/nsdocument/autosavingfiletype) | UI09 failure retained |
| `writeSafely(to:ofType:for:)` | Stock safe publication (C3.6) | DocC | *to evidence* |
| `isInViewingMode` | Unknown-newer read-only (C5) | [isInViewingMode](https://developer.apple.com/documentation/appkit/nsdocument/isinviewingmode) | *to evidence*. Read-only must also block save paths |
| `preservesVersions` / Versions store | Mac decides with evidence. **Not** counted as the M1 prior-checkpoint guarantee | [preservesVersions](https://developer.apple.com/documentation/appkit/nsdocument/preservesversions) | U |
| `NSFileCoordinator` | Per-operation coordinated read/write; never a lock | [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator) | 4 historical serial cases only |
| `NSFileCoordinator.ReadingOptions.immediatelyAvailableMetadataOnly` | Metadata reads in OFF without triggering download (C8) | [DocC](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/immediatelyavailablemetadataonly): "read an item's metadata without triggering a download" | *to evidence*. Provider behavior U |
| `NSFilePresenter` (NSDocument conforms) | External-change detection (C4) | [NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter) | *to evidence* |
| `NSFileVersion.unresolvedConflictVersionsOfItem(at:)` | Surface provider conflict versions as evidence (C4) | [DocC](https://developer.apple.com/documentation/foundation/nsfileversion/unresolvedconflictversionsofitem(at:)) | Provider population **U** |
| `NSApplication.terminate(_:)` ordering | Quit path must reach unsaved-document decisions before delegate termination | [terminate(_:)](https://developer.apple.com/documentation/appkit/nsapplication/terminate(_:)); [native policy report](../research/native-policy-library-readiness.md#native-race-what-was-actually-established) | AS05 partial (G) |
| SwiftUI `DocumentGroup` / `FileDocument` / `ReferenceFileDocument` | **Alternative, not selected** | [DocumentGroup](https://developer.apple.com/documentation/swiftui/documentgroup) (macOS 11+); 27.2 deprecation metadata on file-document protocols (historical observation) | Compile-only historical |

## 3. Sandbox and entitlements (D unless stated)

App Sandbox is **ON** for the M1 app target. Reasons: least privilege; security-scoped access is the documented persistence mechanism in a sandbox; and avoiding later re-architecture for the signed route.

| Entitlement / key | M1 value | Why | Status |
| --- | --- | --- | --- |
| `com.apple.security.app-sandbox` | `true` | Contain damage; least privilege ([DocC](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.app-sandbox)) | *to evidence* in build settings |
| `com.apple.security.files.user-selected.read-write` | `true` | Show documents are created/saved, and the library folder is chosen (C2a), at user-chosen (including cloud) locations via panels ([DocC](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write)) | *to evidence* |
| Bookmark modes (split) | **Sources:** read-only per bookmark (`.withSecurityScope` + `.securityScopeAllowOnlyReadAccess`). **Show documents and the chosen library folder:** read-write (`.withSecurityScope` only) | The entitlement is app-wide read-write, so source immutability is enforced at the source bookmark plus the app's no-write invariant ([DocC](https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/securityscopeallowonlyreadaccess)); documents/library need write access to be reopened from the library after relaunch and saved | *to evidence* (`M1-REF-018/020`, `M1-DUR-029`) |
| `com.apple.security.files.bookmarks.app-scope` | Not added unless a sandboxed build test shows it is required | Apple's current [sandbox file-access article](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) describes security-scoped bookmarks without naming it, and its DocC entitlement page returned **404** on 2026-10-04 | **U**. Mac verifies with an actual sandboxed build |
| `com.apple.security.network.client` / `.server` | **absent** | M1 has no network features. Provider sync runs in the provider's own processes. No telemetry | **D**. A test asserts the entitlement is absent |
| iCloud container / `NSUbiquitousContainers` / CloudKit | **absent** | Canonical documents live at user-chosen locations, not an app ubiquity container | **D** |
| `com.apple.security.files.downloads.*`, assets (music/movies/pictures), device (microphone/camera), personal information | **absent** | Not needed in M1. No recording capture | **D** |
| Speech recognition (`NSSpeechRecognitionUsageDescription`) | **absent** | Speech is M3 (WW-026) | **D** |
| `com.apple.security.get-task-allow` | Debug builds only | Must be absent for notarization (F: [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)) | WW-041 |
| Document type / exported UTI for the show document | Required; identifier chosen by Mac | NSDocument type mapping | **U** until Mac records it |

## 4. Security-scoped bookmark lifecycle (C7)

Basis: Apple, [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) (fetched 2026-10-04).

1. **Grant.**
   - The user selects a source in `NSOpenPanel`. The system extends the sandbox and starts implicit security-scoped access for panel URLs; the app must call `stopAccessingSecurityScopedResource()` when it is done.
   - Folder grants extend recursively.
   - **D:** M1 grants individual files; "Add Folder" is subject to Design/coordinator scope.
2. **Persist.**
   - **Sources:** create bookmark data with `.withSecurityScope` + `.securityScopeAllowOnlyReadAccess`; a source scope is never used for writing.
   - **Show documents (library/recent entries) and the library folder (C2a):** `.withSecurityScope` (read-write), so a show can be reopened from the library after relaunch and saved (`M1-DUR-029`).
   - Store bookmarks **only** in device-local access records/preferences, never in the portable show document.
3. **Resolve on later use.**
   - Resolve with `.withSecurityScope` plus `.withoutUI`/`.withoutMounting` where appropriate.
   - The system does **not** extend the sandbox automatically for resolved stored bookmarks; the app must call `startAccessingSecurityScopedResource()`.
4. **Stale.**
   - If `bookmarkDataIsStale` is true while access is valid, recreate the bookmark and update the access record.
   - Identity stays **unverified**: a stale resolution can point at a replacement file (F: [native policy report](../research/native-policy-library-readiness.md#actual-findings)).
5. **Release.** Every successful start is balanced by exactly one stop on every path (success/error/cancel). Leaked scopes are counted in tests (`M1-REF-016`, gate: zero).
6. **Failure states.** Resolution failure leads to `regrant required`; permission errors to `access denied` (never "missing"); no item to `missing`. All three are distinct.
7. **Not a lock.** A scope grants permission; it does not provide coordination or exclusivity.
8. **G:** sandboxed panel grant → relaunch → resolve → reopen-and-Save proof runs under user grant A of 2026-10-04 (`M1-REF-020`); until it passes, sandbox grant behavior is unevidenced. TCC/ACL/privacy denial is observed separately; POSIX/ACL denials can still occur inside granted scope (F: same Apple article).

## 5. Cloud/provider and ubiquitous-item register

| Mechanism | Use | Status |
| --- | --- | --- |
| `URLResourceKey.isUbiquitousItemKey`, `ubiquitousItemDownloadingStatusKey`, `ubiquitousItemIsDownloadingKey`, `ubiquitousItemDownloadRequestedKey`, `ubiquitousItemDownloadingErrorKey` | Residency/transfer observations (C7/C8) where populated | **F**: DocC (macOS 10.7–10.10+) documents these as **iCloud** keys. **U** whether OneDrive/Dropbox File Provider domains populate them |
| `FileManager.startDownloadingUbiquitousItem(at:)` | ON-mode availability request / explicit Make Available | **F**: DocC "Starts downloading (if necessary)". Never called in OFF except by explicit user action |
| `FileManager.evictUbiquitousItem(at:)` | **Never used by the app**: it would remove local copies of user sources | **D** (prohibited in app code). The grant-C trial harness may run `brctl evict`/`download` on **its own generated files** in `WaveWrangler-M1-Synthetic-Trial` only |
| `NSMetadataQuery` ubiquitous scopes / percent-downloaded key | Not selected: these target app ubiquity containers, not user-chosen locations | **D/U** |
| Moving a provider placeholder | **Prohibited**: it can download/remove the item ([research](../planning/research.md#external-sources-and-file-provider-contract)) | **D** |
| Provider atomicity / ordering | Never assumed | **G**: iCloud Drive observed only via the grant-C trial (`M1-DUR-024`, `M1-SRC-ON-PROV-001`) on this Mac, one folder, synthetic files, folder deleted afterwards. OneDrive/Dropbox (`M1-DUR-030`, `M1-SRC-ON-PROV-002/003`) and second device (`M1-DUR-025`) **not authorized** |

No generic "pending/downloading" classifier is invented. Unknown is shown as unknown.

## 6. Privacy register

| Item | M1 position |
| --- | --- |
| Recordings to external services | **None.** No network entitlement or network code. Provider sync of *user-chosen* locations is the user's provider, outside the app |
| Telemetry / analytics / crash-reporting SDKs | **None** (D) |
| Source content access | None in M1 (no decode/hash/header/preview). OFF makes zero content requests (C8) |
| Logging | Unified logging. Source paths/names are logged only at `private` privacy level, never `public`. No source content. No committed logs with user paths (D; *to evidence* by code review) |
| Device-local data | Access records, published prior checkpoints, unpublished edit-checkpoint records (C2b) and the derived index live in the app container; never source files. The **library location is configurable** (C2a): default app container, or a user-chosen folder (e.g., iCloud Drive/OneDrive/Dropbox) reached via a read-write bookmark and published with C3–C5. While the container default is in use, the app shows "Library stored on this Mac only" (R6) |
| Privacy manifest (`PrivacyInfo.xcprivacy`) | **Recommended** for M1 (D). Required-reason API categories likely touched: `NSPrivacyAccessedAPICategoryFileTimestamp` (modification dates), `NSPrivacyAccessedAPICategoryUserDefaults` (settings), possibly `NSPrivacyAccessedAPICategoryDiskSpace` (disk-full messaging). Categories are F ([DocC](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)); exact reason codes are **U** until Mac lists actual API use. Enforcement on the direct route is **U** → WW-041 |
| Usage-description strings | None needed in M1 (no mic/camera/speech/contacts) |

## 7. Rights, licenses and notices

| Item | M1 position |
| --- | --- |
| Third-party code dependencies | **None expected.** Apple SDK frameworks only (Foundation, AppKit, SwiftUI, UniformTypeIdentifiers, CryptoKit for SHA-256 if used). Any SwiftPM/third-party dependency must be recorded here **before merge**, with exact version, license, notice text and transitive dependencies |
| Models, assets, codecs | None in M1 |
| Notices file | Not required while dependencies = 0. Becomes required when the first dependency is added (G) |
| Patent/legal | No codec/SRC/model use in M1. Later items stay UNKNOWN in WW-018/026/041 |
| Apple SDK terms | Governed by the Xcode/SDK license; no redistribution of third-party code. **U**: no legal review performed or implied |

## 8. Signing, hardened runtime and distribution

| Item | M1 position | Transfers |
| --- | --- | --- |
| Signing | Ad-hoc "Sign to Run Locally"; no team, certificates or credentials (D) | Developer ID → WW-041 |
| Hardened runtime | Enable in the app target (`ENABLE_HARDENED_RUNTIME = YES`) to surface incompatibilities early (D); *to evidence* in build settings | Proof with Developer ID → WW-041 |
| Notarization | **Not performed.** Apple requires a Developer ID signature, hardened runtime, secure timestamp and no `get-task-allow` (F: [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)). Notarization is not App Review or a legal/quality assurance | WW-041/052 |
| Clean install / grant / relaunch matrix on a fresh account/device | Not performed | WW-052 |
| App Store | First launch deferred; no paid/legal budget assumed | — |
| CI | Minimal native build/test CI is allowed by the kickoff; no signing secrets, deployment, upload or release automation | — |

## 9. Native Speech eligibility (M3, not selected)

**F:** [`SpeechTranscriber`](https://developer.apple.com/documentation/speech/speechtranscriber) is documented as introduced in macOS 26.0, with device-support checks advised. It remains *eligible* for a fair native-vs-Whisper evaluation in [WW-026 (#23)](https://github.com/brandonmartinez/WaveWrangler/issues/23). **D:** M1 does not link or import Speech, request speech permission or provision assets. The WhisperKit tokenizer network fallback stays retained as M3 evidence.

## 10. Explicit unknowns

1. Exact public AppKit hooks for honest OFF skipping and dirty-Quit coverage (AS01 unestablished, AS05 partial).
2. Whether `files.bookmarks.app-scope` is needed on current macOS for persisted security-scoped bookmarks.
3. File Provider (OneDrive/Dropbox) population of ubiquitous keys, coordination semantics, conflict versions and placeholder behavior.
4. iCloud Drive publication ordering/atomicity for whole-file replace under coordination (partially observable in the grant-C trial; not generalizable).
5. macOS 26 runtime behavior and 16 GB performance.
6. Privacy-manifest reason codes and their direct-distribution enforcement.
7. The show-document UTI/extension identifier (Mac to record).
8. `preservesVersions` behavior on cloud locations.
9. Whether the user wants a device-local crash snapshot while autosave is OFF (WW-009 Q3).
10. Whether nested coordination for the C3 base check inside AppKit's coordinated save is safe, and where a library folder's provider conflicts surface (`NSFileVersion`) for a non-`NSDocument` file.

## 11. Acceptance mapping

| WW-008 criterion | M1 disposition | Transfer |
| --- | --- | --- |
| Exact floors evaluated against macOS 26+/Apple silicon/English | §1. Target 26 compile *to evidence* in Mac's build; claimed host recorded | macOS 26 runtime / 16 GB / 8 GB → WW-052 |
| 16 GB initial reference, 8 GB later, Intel/non-English deferred | Recorded §1; no claim made | WW-052 |
| Fair native Speech eligibility, not selection | §9 | WW-026 |
| Direct signed/notarized grant/reopen/cancel with zero source writes | **Internal:** ad-hoc sandboxed grant/reopen/cancel with zero source writes via `M1-REF-*` (programmatic) + `M1-DUR-029` (relaunch reopen+Save) + `M1-REF-020` (GUI, grant A) | Signed/notarized artifact → WW-041/052 |
| Signing/hardened runtime/permissions/privacy/notices 100% identified | §3, §6, §7, §8 (this register) | Artifact proof → WW-041 |
| Artifact-specific license/patent unknowns explicit | §7, §10 | WW-018/026/041 |
| App Store deferred; no paid/legal budget; notarization ≠ App Review | §8 | — |
| Safe internal-use envelope | §1 envelope + WW-009 contracts | — |

**Gate:** WW-008 M1 closure requires this register, Mac's build-settings evidence for §3/§8 (sandbox ON, entitlements exactly as listed, hardened runtime, deployment target 26, no network entitlement, dependency count = 0) and resolution or explicit carry of each §10 unknown.
