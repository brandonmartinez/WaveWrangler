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
  - It runs when a window of the document first appears, on **every** display path: `showWindows()`, a window restored at launch by state restoration (via the show window's attach, since restoration never calls `showWindows()`; #107 review), or the next turn after a revert. A document that is never displayed presents neither, so its deferred work runs once one of its windows appears.
- **Library bookkeeping (`LibraryUIStore.showDidOpen`) runs after the show window's first commit.** It updates and re-renders the Library window (entry details, Last Opened, recents), which previously happened inside the pass that committed the show window.
  - It reads the document's state when it runs, so a save in between is never recorded over by an older title.

## Native before/after (direct launch, 2026-10-05)

**Method:**
- **Builds:** local Debug builds of the acceptance lane's branch (`cb42138`, with its `Responsiveness` instrumentation and the `lib100files` fixture).
  - **Before:** unmodified.
  - **After:** merged with this branch at `ccb6c19`.
- **Trigger:** a local-only `-WWMeasureOpenRow N` hook (never merged) opens entry N through the normal `LibraryWindowState.open` path, 1 s after the library is ready, then quits. Rows rotate 3–99.
- **Samples:** 100 fresh processes per variant, launched directly (no XCUITest) under the GUI lock. Claimed host: Apple M5 Max, macOS 27.0.1. Percentiles are nearest-rank.
- **Metric:** the acceptance lane's `show.open` interval, ending at the commit after the show window attaches. Its start is shown two ways:

| `show.open`, first open in a fresh process | p50 | p95 | max | ≥ 0.9 s |
|---|---:|---:|---:|---:|
| Before, from the `open()` handler | 241 ms | 295 ms | 345 ms | 0/100 |
| After, from the `open()` handler | 232 ms | **274 ms** | 323 ms | 0/100 |
| Before, from "event" timestamp (as reported) | 270 ms | 1,267 ms | 1,286 ms | 27/100 |
| After, from "event" timestamp (as reported) | 238 ms | 1,255 ms | 1,317 ms | 26/100 |

**Finding: the slow mode is a measurement artifact, not product time.**
- `Responsiveness.begin` uses `NSApp.currentEvent.timestamp` whenever that event is less than 1 s old.
- With no input event (the programmatic open), the current event in about 26% of launches was a stale launch/activation event 933–1,000 ms old. The bound comes from the `< 1 s` guard.
- In those samples, every `ShowOpen` stage took the same time as in fast samples, and the main thread was idle; the gap is the hook's own 1 s wait.
- **The XCUITest harness is not affected (verified).** In its 30-sample run, the event that started `show.open` was the Return keyDown (keyCode 36, about 6 ms old) in every sample. So the harness's start time is correct, and its slow samples are real time.

### XCUITest harness: 30 cold samples, "after" build, with event logging (2026-10-05)

`ResponsivenessUITests.testColdLaunchAndFirstOpen` with `WW_SCALE_SAMPLES=30`, on the local "after" build. A local-only log line
records the type, key code and age of the event that starts `show.open`.

| `show.open` (n = 30) | p50 | p95 | max | ≥ 0.9 s |
|---|---:|---:|---:|---:|
| From the Return keyDown | 281 ms | 317 ms | 904 ms | 1/30 |

Stage medians across the 30: open request → `document.init` 8 ms; `makeWindowControllers` 111 ms; `window.attachCommit` 65 ms.

The one slow sample (904 ms) had two stalls, both outside persistence:
- **~250 ms inside `NSDocumentController.openDocument`** before the document was created (median 8 ms).
- **A 453 ms commit after the window attached** (median 65 ms).

Its persistence stages (read, decode, deferred work) were normal. This sample can't attribute the stalls further. A spindump or a
Time Profiler trace of a slow launch is needed, for example to rule out XCUITest's accessibility snapshots, which run on the app's
main thread.

These 30 samples aren't comparable with the acceptance lane's 100-sample run on `cb42138` (different build, smaller n). **No gate
result is claimed from them.** The SCALE-001 native first-open gate stays as the acceptance lane measured it until its holdout is
re-run.

**Stage attribution (after, n = 100, p50 / p95):**
- `library.openShow` 209 / 226 ms (the Task through NSDocumentController's return), which includes:
  - `document.makeWindowControllers` 123 / 130 ms (hosting controller, SwiftUI view graph);
  - `document.read` 2.4 / 3.8 ms (`document.decode` 2.3 / 3.6 ms);
  - `document.init` 0.5 / 0.7 ms.
- `window.firstCommit` 95 / 133 ms.
- `window.attachCommit` 23 / 57 ms.
- Moved after the first frame: `document.deferred` 0.27 / 0.31 ms and `library.showDidOpen` 0.15 / 0.16 ms. The Library window's re-render is no longer inside the show window's commit.

**Change, handler-measured:**
- p95 295 → 274 ms (−21 ms), p50 241 → 232 ms, max 345 → 323 ms.
- The remaining cost is AppKit/SwiftUI window creation and first layout (about 220 ms), which persistence doesn't own.
