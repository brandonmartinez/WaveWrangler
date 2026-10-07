# M2 GUI baseline

**Recorded:** 2026-10-06 · **Revision:** `348af4576a5a2502581fdf96e1f0c87b059d6743` (`origin/main`) · **Purpose:** M2's first capped full UI-regression run and the pinned comparison baseline for later M2 UI PRs. This is a baseline record, not M2 exit evidence.

## Gate results

| Gate | Host | Classes | Result | Result bundle |
| --- | --- | --- | --- | --- |
| Shard A | Mac mini “Macsimus” (M2 Pro, macOS 27.0.1) | `SourceGrantHoldoutUITests`, `LifecycleHoldoutUITests`, `DocumentLifecycleUITests`, `OfflineSaveKeyboardUITests`, `LibraryLocationUITests`, `LibraryProviderConflictUITests`, `LibraryManagementUITests` | 27 pass / 0 fail / 0 skip | `~/ww-uitest-runs/m2-regression-348af45/mini.xcresult` |
| Shard B | This Mac (M5 Max, macOS 27.0.1) | `ResponsivenessUITests`, `SheetKeyboardUITests`, `LibraryWorkspaceUITests`, `EpisodeSetupUITests`, `SelectionContrastUITests`, `ContrastEvidenceUITests`, `VoiceOverWalkUITests`, `CoreTasksKeyboardUITests` | 40 pass / 2 fail / 4 skip | `~/ww-uitest-runs/m2-regression-348af45-local/local.xcresult` |
| Full UI suite | Both hosts, one lock per host | Shards A+B | **67 pass / 2 fail / 4 skip** | Paths above |
| Headless suite | This Mac | `scripts/test.sh` | **Pass** | `.build/m2-gui-baseline-headless-derived/Logs/Test/Test-WaveWrangler-2026.10.06_17-40-43--0400.xcresult` |

The Mac mini shard completed in 1,191 s; the local shard completed in 1,989 s. The class split kept the 151 s source-grant holdout with the mini shard and the broader local interaction/contrast set on this Mac.

### Failure triage

| Finding | Classification | Disposition |
| --- | --- | --- |
| `CoreTasksKeyboardUITests.testT16ConflictNeverOverwrites` | Deterministic: failed in the full shard and in its only permitted isolated rerun. | Existing deferred conflict-resolution work, #66. Not a new finding. |
| `ContrastEvidenceUITests.testLibraryTextContrastAcrossAppearances` | Flaky audit infrastructure: initial `XCUIAccessibilityAudit` contrast pass timed out (`-56`), then passed in its only isolated rerun. | Follow-up #218. No product contrast failure was observed. |
| `ResponsivenessUITests.testInteractions` | Deterministic timing regression: episode-switch event-to-commit p95 exceeded 100 ms in the initial, isolated-rerun, quiet-mini, and quiet-local 100-sample runs. | P1 follow-up #220. |
| Setup dark 200% blocked/recovery status contrast | Unwaived measured contrast finding: 31,772 glyph pixels at p75 2.29:1. | P1 follow-up #221. |

The local result bundles include expected skips for the three VoiceOver-walk tests (VoiceOver was not enabled) and the system-visual settings test. Those are user-manual/M5 scope, not passes.

## Essential accessibility audit waiver baseline

The essential audit set is `elementDetection`, `sufficientElementDescription`, `hitRegion`, and `action`; `.contrast` is considered only for blocked or recovery surfaces. The keyboard core-task audit surfaces (new show, episode inspector, conflict sheet, recovery offer, and unknown-newer refusal) had no unwaived essential findings on this revision.

The table pins every observed waiver class and its rationale at `348af457`. A later M2 PR fails the essential-audit comparison when it introduces a new waiver class, exceeds a stated cap, or produces an unwaived finding. The raw per-element evidence remains in the shard result bundle; no screenshots are committed without a finding.

| Audit finding / surface | Audit type | Baseline | Reason | Disposition |
| --- | --- | ---: | --- | --- |
| Disabled SwiftUI layout groups, import review | `sufficientElementDescription` | 39 (cap 39) | Non-interactive layout containers. | Audit artefact |
| Disabled SwiftUI layout groups, Setup | `sufficientElementDescription` | 65 (cap 67) | Non-interactive layout containers. | Audit artefact |
| System pop-up `AXShowMenu`, import review / Setup | `action` | 10 / 2 (caps 10 / 2) | System pop-up controls expose `AXShowMenu`; app actions remain labelled. | Audit artefact |
| Window/tool/menu/touch-bar chrome | `sufficientElementDescription` | 1 per audited surface at most | System window chrome, not app content. | Audit artefact |
| Siri overlay | `sufficientElementDescription` | 0–1 (cap 1) | System Siri overlay, not app UI. | Audit artefact |
| AppKit sheet icon | `sufficientElementDescription` | 1 on T17/T20 | Decorative `NSAlert` icon; the alert text carries the message. | Audit artefact |
| Setup source-name cells | `sufficientElementDescription` | 2 unwaived filename-heuristic reports | AX audit calls ordinary visible file names such as `ana-zoom.m4a` and `intro.wav` “not human-readable”; the names are the intended visible labels. | Audit artefact |
| Library 200% HelpTag | `sufficientElementDescription` | 1 | AppKit HelpTag without an app-owned description. | Audit artefact |
| Setup source status, dark 200% blocked/recovery state | `contrast` | 1 unwaived report | Measured p75 2.29:1 at 31,772 glyph pixels. | Accepted with issue #221 |

### Broad (M5) observations

The following are informational broad-accessibility observations for M5 / WW-053, not entries in the M2 essential-audit waiver baseline: fully offscreen or partly clipped library-cell contrast reports (`notOnScreen` 0–2, cap 5, plus four two-point bottom-edge samples); one library dark-collection-row report measured at p75 15.72:1 where the audit samples sidebar material; and sidebar, table, non-blocked Setup-cell, title, and sheet-text contrast reports within existing per-surface `tableText` caps (import 1/1, Setup 1/4). Pixel evidence meets the 40-glyph / p75 4.5:1 measured-artefact rule, or the content is dimmed or occluded while the audit measures the frontmost surface.

## Responsiveness baseline

The M1 `Responsiveness` instrumentation recorded application event-to-committed-run-loop timing; p95 uses nearest rank. The initial local 100-sample run measured 111.524 / 127.612 ms (p95 / max) for episode switching under concurrent heavy work and approximately 30 one-minute load. Its required isolated local rerun measured 109.097 / 115.297 ms under the same contaminated condition. Both remain in #220 as contaminated-condition observations, not quiet-host baseline measurements.

The quiet-host runs below are **load-condition checks**. Macsimus began at 3.69 one-minute load and ended at 4.94; this Mac began at 6.14 and ended at 6.52. Result bundles and extracted JSON remain host-local:

- Mac mini: `~/ww-uitest-runs/m2-regression-348af45/responsiveness-100-mini.xcresult` and `responsiveness-100-mini.json`.
- This Mac: `~/ww-uitest-runs/m2-regression-348af45-local/responsiveness-100-quiet-local.xcresult` and `responsiveness-100-quiet-local.json`.

| Metric | Samples | Gate | Mac mini p95 / max (ms) | This Mac p95 / max (ms) | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| Launch to Library ready | 100 | <1000 | 858.934 / 1056.802 | 644.244 / 707.707 | Pass |
| First cold show open | 100 | <1000 | 829.857 / 988.083 | 458.003 / 638.957 | Pass |
| Warm show open | 100 | <1000 | 263.699 / 291.028 | 235.978 / 254.119 | Pass |
| Library sidebar selection | 103 | <100 | 71.070 / 86.664 | 62.152 / 76.037 | Pass |
| Collection edit | 100 | <100 | 39.913 / 79.344 | 29.424 / 40.486 | Pass |
| Episode switch | 100 | <100 | 107.793 / 119.962 | 106.201 / 125.829 | **Fail; #220** |
| Metadata edit | 100 | <100 | 31.023 / 37.970 | 36.501 / 66.872 | Pass |
| All interactions | 403 | <100 | 102.332 / 119.962 | 97.793 / 125.829 | Mini fail; local pass |

The episode-switch handler-to-commit p95 remained below 100 ms on both quiet hosts (92.522 ms on the mini; 70.084 ms locally); the user-visible event-to-commit metric did not. None of the initial run, isolated rerun, or quiet-host load-condition checks waives #220: it remains a hard-gate **FAIL** until fixed.

## Baseline revision — 2026-10-06 (`792eee80853e11403b92e307a7609d95cabbd53a`)

The Setup source-name `sufficientElementDescription` audit-artifact waiver also covers the golden F-OLDER fixture names in `WaveWranglerUITests/FormatUpdateUITests.swift` and `Packages/WaveWranglerKit/Tests/WWPersistenceTests/ShowSchema1Fixtures.swift`. Those fixture names are frozen ShowSchema1Fixture bytes used to exercise the v1-to-v2 migration path; they are visible intended file labels, not missing descriptions.

## Baseline maintenance

Only a reviewed PR may change this file. Subsequent M2 PR runs compare their affected classes with this record and fail on new UI-test, essential-audit, or responsiveness findings. Existing items remain failures or accepted follow-ups until their evidence is updated in a reviewed baseline revision.

Refs #20
