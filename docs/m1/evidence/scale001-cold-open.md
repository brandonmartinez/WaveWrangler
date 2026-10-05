# M1-SCALE-001 native cold first open: attribution and deferrals

Owner: persistence lane (Mac). Context: the acceptance lane's native SCALE-001 run measured the first show opened in a fresh
process at p95 1.048 s and max 1.116 s, against the frozen provisional gate of < 1 s. The distribution was bimodal: about 20% of
runs fell at 0.91–1.12 s.

## Signposts (for attribution)

Subsystem `com.brandonmartinez.wavewrangler`, category **`ShowOpen`**. These are os_signpost intervals, recorded whenever
signposts are collected (Instruments, `xctrace`, `log stream --signpost`). Debug runs launched with `-WWUITestTimingLog YES`
(the acceptance lane's timing flag) also log one `WWOPEN stage=<name> ms=<ms>` line per interval. Release builds never write
these lines.

| Interval | From → to |
|---|---|
| `library.openShow` | Library open request → NSDocumentController returns the document (both library backends) |
| `document.init` | `ShowDocument.init` |
| `document.read` / `document.decode` | `read(from:ofType:)` / envelope decode, checksum and strict validation |
| `document.makeWindowControllers` | Hosting controller and window creation |
| `window.firstCommit` | `showWindows()` → end of the run-loop pass that committed the first frame |
| `window.attach` / `window.attachCommit` | Post-attach work (toolbar bridging, chrome) / through its commit (the acceptance lane's `show.open` endpoint) |
| `document.deferred` | Work moved after the first frame: `NSFileVersion` conflict inspection and the C2b offer scan |
| `library.showDidOpen` | Library bookkeeping (location, summary, Last Opened, recents), now after the show window's first commit |

## Headless evidence: the data layer is not the cost

Method: 100 fresh `wwpersist-probe profile-open` processes (Debug, claimed host: Apple M5 Max, macOS 27.0.1), one cold open
each, on a synthetic 1,770-byte show. Each process runs the same calls the app's open path makes. Percentiles are nearest-rank.

| Stage (cold process) | p50 | p95 | max |
|---|---:|---:|---:|
| File read | 0.04 ms | 0.05 ms | 0.05 ms |
| Decode, checksum, strict JSON, validation | 1.34 ms | 1.44 ms | 1.47 ms |
| `NSFileVersion` conflict inspection | 4.49 ms | 5.05 ms | 5.72 ms |
| C2b set-aside | 0.02 ms | 0.03 ms | 0.05 ms |
| C2b offer scan | 0.03 ms | 0.04 ms | 0.05 ms |
| Library show-locations store init | 0.10 ms | 0.12 ms | 0.29 ms |
| Bookmark resolve and security-scope start | 1.62 ms | 1.86 ms | 4.20 ms |
| Coordinated identity-verify open | 2.78 ms | 3.08 ms | 4.19 ms |
| **Sum** | **10.49 ms** | **11.40 ms** | **13.36 ms** |

Over 98% of the ~1 s native first open is therefore outside persistence. It is in AppKit's document machinery, window and
SwiftUI first layout, other main-thread work in the same run-loop passes, or the harness.

Limits:
- The probe is unsandboxed. In the sandboxed app, bookmark resolution goes through the system's scoped-bookmark service and may cost more.
- The probe's show is smaller than the `lib100files` shows (5 episodes × 10 references each); decode scales with size and is about 1 ms here.

## Changes (no safety check removed; work is deferred, not dropped)

- **Provider-version inspection and the C2b offer scan run after the window's first frame.** Neither decides anything before then: the offer's actions re-check against disk when used, and saving depends on neither.
  - The C2b **set-aside stays synchronous** in `read`. It is what protects edit-checkpoint records from an immediate save or a new checkpoint, and it costs about 0.02 ms.
  - A document that is never displayed presents neither, so its deferred work runs only if its windows are shown.
- **Library bookkeeping (`LibraryUIStore.showDidOpen`) runs after the show window's first commit.** It updates and re-renders the Library window (entry details, Last Opened, recents), which previously happened inside the pass that committed the show window.
  - It reads the document's state when it runs, so a save in between is never recorded over by an older title.

## Native before/after: pending

XCUITest automation is blocked while Automation Mode awaits user authentication. The planned measurement launches the app
directly, without XCUITest:
- **Builds:** local Debug builds of the acceptance lane's branch (`cb42138`, which carries its `Responsiveness` `show.open` instrumentation and the `lib100files` fixture), unmodified ("before") and merged with this branch ("after").
- **Trigger:** a local-only `-WWMeasureOpenRow` hook (never merged) opens an entry through the normal `LibraryWindowState.open` path.
- **Samples:** 100 fresh processes per variant, under the GUI lock.

That run also tests whether the bimodal ~20% depends on XCUITest's 50 ms accessibility polling during the open. No native
improvement is claimed until it has run.
