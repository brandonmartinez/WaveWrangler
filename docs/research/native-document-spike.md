# Native document spike — finite evidence and integration

> **Publication notice:** This report describes archived historical evidence and phase permissions, not current execution authority. Public JSON companions are pointer-redacted and **NOT byte-identical archived mirrors**; [original versus published hashes](../planning/publication-provenance.json) are separate. Measurements, pins, artifact hashes, counts and failed controls remain unchanged. Local archive placeholders are not browsable repository links. [Current user-directed milestone policy](../planning/milestone-runbook.md) supersedes old no-issues/research-only phase restrictions without granting input consent.

**Date:** 2026-10-04 · Mac: experiment author/platform evidence · Design: actual evidence review · Lead: report, backlog and final-metadata integration.

## Outcome and acceptance

**Lead verdict: accept-with-limits for evidence integration and the next bounded research candidate; not architecture adoption, a completed research spike, M1 authorization or shippable code.** The separate native batch is closed. No compiler, native runner, UI or reproduction was invoked during integration.

- **28 qualified passes / 0 failed assertions:** **24 native runtime cases** (17 NSDocument, four NSFileCoordinator, two FileWrapper, one plain bookmark), **one public SwiftUI snapshot runtime case**, **three compile/control cases**. Nine overlapping blocked limits are exclusions, **not nine more executed tests or 37 independent observations**.
- **13 native completions:** ten Save/three autosave, nine successes/four expected failures, all main-thread, zero missing/duplicate callbacks. Errors retain subclass/OS provenance; expected error assertions pass rather than being hidden failures.
- Last-edit-to-independent-coherent-disk observations **0.129026042 / 0.292939875 / 0.546012500 seconds** pass provisional ≤2s only for three finite cases; two use custom timers. Custom OFF observed no checkpoint for **0.45s**, then explicit Save persisted.
- Genuine superclass save/autosave and URL/change-count management ran, but a research `writeSafely` override staged inside scratch using `super.write` plus Foundation publication. **Stock AppKit safe publication was not exercised.** Scheduling was suppressed, versions disabled; schema/stale/error/snapshot/timer policies are not native guarantees.
- **Candidate-not-adopted:** NSDocument + SwiftUI views/versioned single-file JSON values. DocumentGroup and packages remain viable; SQLite is untested in this native batch. Do not transplant the override, RunLoop sleeps, unchecked sendability or serial preflight into production.
- Backlog remains **LOCAL**: **51 stable IDs / 196 unchanged acyclic edges; 3 documentary-completed / 14 partial / 34 pending**. WW-008 alone changes pending → narrowly partial; WW-007 stays pending. WW-004 remains documentary-only; WW-009/M1/WW-010–012 remain pending and unapproved. No issues were created; future promotion is conditional on completed planning/research under [Brandon's directive](../../.squad/decisions/inbox/copilot-directive-2026-10-04-native-document-local-backlog.md).

[Compact repository metadata](native-document-results.json) is a public sanitized-provenance companion of the authoritative local results.json (`<research-artifacts>/research/macos-document/results.json`; local archive), **not a byte-identical mirror after pointer redaction**. Full source, fixtures, events and logs remain in the archived local artifacts below, not duplicated in the repository. [Original and published hashes](../planning/publication-provenance.json) are recorded separately.

## Scope, chronology and measured environment

Synthetic/disposable own-file scope only: no user media or sample metadata, cloud/provider/network-writing trial, install/package/model/SDK download, production app scaffold, signing/notarization/TCC/preferences/window/UI activation. Native services may inherently manage metadata for synthetic files; this is **not a system-wide activity trace or proof of zero hidden OS activity**. No old foundation experiment was rerun or imported. Historical [foundation report](foundation-spikes.md) and [numerical results](foundation-results.json) are unchanged; its **169 calibration / 5,728 primary heldout** accounting does not include or combine with these native conformance cases.

| Measurement | Actual native-batch evidence |
| --- | --- |
| Runtime host | macOS **27.0.1**, build **26A434**, **arm64** |
| RAM | **137438953472 bytes / 128 GiB**; not 16GB reference evidence |
| Compiler | Apple Swift **6.4**, swiftlang **6.4.0.34.1**, clang **2100.3.34.1** |
| SDK | `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk` |
| Build target / language | `-target arm64-apple-macos26.0 -swift-version 5`; SwiftUI also `-parse-as-library` |
| Qualified sources | native **v3**, SwiftUI **v2**; executable basenames retaining `v1-c3` are runner naming, not v1 source |
| Freeze | **2026-10-04T14:57:39.109203Z** |
| Native qualification start / end | **14:57:39.150101Z / 14:57:41.897554Z**, same date |

Plan (`<research-artifacts>/research/macos-document/experiment/plan-v1.json`; local archive) precedes qualification; prequalification manifest (`<research-artifacts>/research/macos-document/experiment/prequalification-manifest.json`; local archive) records source/plan/fixtures/executable freeze and `fixed_before_qualification=true`. The supplied summaries report unchanged frozen bytes. Lead checked the exact entry-artifact hashes, not a new source-wide reproduction/rehash. This is **finite native conformance after preserved corrections**, not a statistical unseen holdout. Cases share fixtures/state and serial operations; repeated callbacks are not independent device/workflow validations. Target26 compilation does **not** establish macOS26 runtime, 16GB performance or Swift6 strict concurrency.

### Preserved failures and final correction

1. **c1:** two invalid harness compile failures (throwing expressions, Darwin `clock()` collision, wrong reference DocumentGroup initializer), no native runtime. Original sources and full logs remain.
2. **c2:** corrected builds compile; native debug **21 pass / 3 fail**, ND07/ND12/ND13. Native dirty/undo notifications were still pending. Immediate autosave returned genuine success without writing a checkpoint. **Successful no-op autosave callback ≠ persistence** remains a finding after qualification succeeds. SwiftUI snapshot passed.
3. **c3:** last allowed correction drains native default RunLoop notifications after edits/undo/redo, without manually faking counters or weakening dirty/save/≤2s assertions. Native debug **24/24** plus SwiftUI snapshot pass, followed by freeze and one qualification. No further qualifying rerun or correction.

Two **intentional negative compiler controls** SU03/SU04 satisfy their planned assertions and are separate from c1's invalid failed builds and c2's failed runtime assertions. Exact failure/build/debug/qualification paths and hashes remain in the named inventory (`<research-artifacts>/research/macos-document/experiment/artifact-hashes.json`; local archive) and appendix.

## Case accounting and API provenance

Each row below describes the observed surface **and** its policy boundary. `native-runtime`, `compile-only`, `subclass-policy`, and `blocked` in the compact metadata classify claim scope, not interchangeable independent-test denominators. Many native cases also exercise explicit subclass policies.

| Cases / qualifying count | Observed API / outcome | Scope boundary |
| --- | --- | --- |
| ND01–ND03 / 3 | `data(ofType:)`, native `read(from:ofType:)`; exact show/two-episode roundtrip; newer/malformed read refusal and unchanged inputs | Schema refusal is subclass validation, not AppKit migration or newer-format edit/save prevention |
| ND04–ND06 / 3 | Native Save As/completion/reopen/URL updates; direct `write(to:ofType:for:originalContentsURL:)` honors caller target distinct from `fileURL`; prior valid bytes retained | Native read/write/save path with controlled safety override, not native panel UX or stock safe publication |
| ND07 / 1 | Named UndoManager undo/redo; exact state and native dirty→clean→dirty observations | RunLoop delivery required; no Edit menu, focus, keyboard or VoiceOver task |
| ND08–ND10 / 3 | Native completion surfaces injected write/cancellation and actual Foundation non-directory publication errors; prior valid bytes retained | Injected cancellation is not native save-panel cancellation; error origin is explicit below |
| ND11–ND12 / 2 | Two NSDocuments: first publishes, stale second refuses; explicit native Save persists/clears dirty | Serial subclass stale preflight has **TOCTOU**, not atomic CAS/multi-process conflict handling |
| ND13–ND16 / 4 | Explicit native in-place autosave; two custom debounce settings; finite custom OFF then explicit Save | Actual superclass autosave, not automatic AppKit idle cadence or visible default/configurable/OFF wiring |
| ND17 / 1 | Native reopen of a custom retained valid snapshot after deliberate canonical corruption | Retained-copy policy, **not crash/power-loss/native-revision recovery** |
| FC01–FC04 / 4 | Actual NSFileCoordinator write/read accessors: staged publication; injected prepublication failure; **20 accepted / 20 stale-refused** alternating cooperative serial writers; coherent read | **21 successful publications**, one injected failure, one coordinated read, zero framework coordination errors, zero parallel workers; custom accessor/stale failures are separate from framework errors |
| FW01–FW02 / 2 | Actual directory FileWrapper write/read and standalone wrapped malformed/newer data refusal | Atomic option is not package/provider transaction proof; FW02 is **not malformed/newer package migration** |
| BM01 / 1 | Actual plain bookmark creation/resolution for immutable generated local source, non-stale | No security scope/sandbox/denial/regrant/stale-refresh/relink/cross-device or portable-identity proof |
| SU02 / 1 | Direct public `ReferenceFileDocument.snapshot(contentType:)` preserves prior value after mutation | Serial-only `@unchecked Sendable`; no asynchronous safety, native serialization callback or app scene |
| SU01 / 1 | Genuine FileDocument/ReferenceFileDocument and both DocumentGroup declarations compile for target26 | **Compile-only**, scene/App.main never executed |
| SU03–SU04 / 2 | Inaccessible Read/WriteConfiguration initializers rejected; ungated Document rejected for target26, gated use compiles | Expected compiler controls, not native workflow failures; **Document requires macOS27** |

Installed SDK old-protocol guidance includes `deprecated: 100000.0`; future `deprecatedAt27.2` metadata is not runtime removal. Configuration construction limits do not establish broken DocumentGroup serialization. Keep the older target26 protocol path viable pending actual app-scene research.

### Native completion ledger

Observed operation enum values: **0 `.saveOperation`**, **1 `.saveAsOperation`**, **2 `.saveToOperation`** (direct ND05 write, no completion), **4 `.autosaveInPlaceOperation`**.

| Completion cases | API / operation | Count / observed error origin |
| --- | --- | --- |
| ND04, ND06 | superclass `save(to:ofType:for:completionHandler:)`, `.saveAsOperation` | 2 successes |
| ND08 | same native Save As | 1 expected failure: subclass `Research.InjectedWrite/73`, retained as underlying error/context by AppKit |
| ND09 | same native Save As | 1 expected failure: actual Foundation publication `NSCocoaErrorDomain/512`, underlying Cocoa/512 → `NSPOSIXErrorDomain/20` (not a directory), wrapped by AppKit; not stock safety publication |
| ND10 | native save, `.saveOperation` | 1 expected failure: injected `NSCocoaErrorDomain/3072` cancellation, same underlying domain/code; no panel |
| ND11 | two native saves, `.saveOperation` | 1 success + 1 expected subclass stale failure `Research.StaleRevision/409`, same underlying domain/code |
| ND12, ND16, ND17 | native save, `.saveOperation` | 3 successes |
| ND13, ND14, ND15 | superclass `autosave(withImplicitCancellability:completionHandler:)`, `.autosaveInPlaceOperation` | 3 successes |
| **Total** | **10 Save + 3 autosave** | **13 completions = 9 successes + 4 expected errors**, all main-thread, zero missing/duplicates |

Read refusals are separate: ND02 `Research.Schema/99`; ND03 JSON decode Cocoa/4864 underlying Cocoa/3840. FC02 custom **accessor** error `Research.BeforePublication/74` is not a native completion or coordination NSError. Raw events retain full nested descriptions/paths; the compact mirror keeps domain/code/provenance rather than duplicating the logs.

## Checkpoint measurements and acceptance limits

**Start:** monotonic DispatchTime at last completed model mutation/undo grouping, **before RunLoop dirty-notification drainage**. **End:** first independent JSONSerialization disk read matching complete show/episodes/revision truth and hash after native completion. Python separately reparses final bytes and verifies truth/hashes (19 checks reported in compact evidence). These are not serializer duration or callback-duration measurements.

| Case | Driver / actual operation | Last-edit → coherent disk (seconds) | Provisional ≤2s |
| --- | --- | ---: | --- |
| ND13 | Explicit native autosave / in-place | **0.129026042** | PASS |
| ND14 | Custom cancel/reschedule Timer **0.15s**, two edits → native autosave | **0.292939875** | PASS |
| ND15 | Custom cancel/reschedule Timer **0.4s**, two edits → native autosave | **0.546012500** | PASS |
| ND16 | Custom OFF, automatic native scheduling suppressed | **0.45s finite no-checkpoint window**, then explicit Save | OFF subset only; not a cadence guarantee |

The earlier foundation **0.004300041s publication operation** remains a different historical metric; these observations do not retroactively relabel it. Qualification success does not erase c2's successful no-checkpoint autosave. Independent disk coherence is narrower than durability, automatic cadence, app termination recovery or cloud synchronization.

## Nine overlapping blocked limits

`qualification-summary.limits` contains **BL01–BL08 only**; both supplied `cases` arrays contain **BL01–BL09** and their counts report nine. Integration carries BL09 explicitly; it is a publication exclusion, not a tenth case or a newly executed test.

| ID | Unestablished / blocked scope |
| --- | --- |
| BL01 | Real save-panel cancellation; injected ND10 does not substitute |
| BL02 | Automatic AppKit idle cadence/default controls, menus/close prompt/app-scene lifecycle; scheduling suppressed |
| BL03 | Unnamed native autosave/OS autosave storage; not invoked; elsewhere autosave also untested |
| BL04 | Native FileDocument/ReferenceFileDocument read/write configurations; DocumentGroup scene unexecuted |
| BL05 | Cloud/provider/offline/hydration/two-machine trials, separately permissioned |
| BL06 | macOS26 runtime, 16GB reference, keyboard/VoiceOver and actual application lifecycle |
| BL07 | Disk-full, process crash/power loss, native revision-store recovery |
| BL08 | Native SQLite comparison and architecture adoption; package/single-file selection remains open |
| **BL09** | **Stock AppKit `writeSafely` publication bypassed** under scratch-only scope; controlled subclass publication is separately classified |

## Architecture recommendation and counterexamples

**Status: candidate-not-adopted.** NSDocument + SwiftUI views with versioned single-file JSON value snapshots is a reasonable next bounded lifecycle candidate because native save/URL/change-count/undo/error paths now have finite direct evidence and lightweight multi-episode state is inspectable. This is not measured JSON scale superiority, product-code approval, a cloud atomicity result or a format commitment.

Keep **DocumentGroup** viable: genuine protocol/scene compilation and serial public snapshot evidence do not rank its unexecuted lifecycle below an AppKit production implementation. Keep **FileWrapper packages** open for later multi-file assets after migration/transaction/provider tests. **SQLite remains untested in this native batch**; do not infer comparative durability from historical foundation code.

Load-bearing counterexamples remain:

- c2 successful no-op autosave lacked persistence; callback success cannot drive a saved indicator by itself.
- Serial stale preflight races between check/publication; neither NSDocument nor serial cooperative access establishes atomic compare-and-swap.
- Retained-copy recovery needed explicit policy after deliberate corruption; no crash/native-version promise follows.
- Stock safety publication/versions/scheduling were bypassed; controlled scratch staging is not a recommended production substitute.
- RunLoop sleeps and `@unchecked Sendable` are probe accommodations, not concurrency or native-lifecycle designs.
- FW02 standalone wrapper validation does not retire malformed/newer package migration, and read refusal does not retire newer-format **edit/save** prevention.

Cloud canonical MVP policy remains accepted; **local tests do not authorize a local-only rescope**. Source-download default ON/configurable/OFF remains policy, not permission for samples/provider/model access.

## Owned remaining gates

No gate below authorizes its own execution. Mac and Design require separately bounded approval and permitted app/provider/device availability; production remains gated at WW-009.

| Owner / backlog | Next required evidence |
| --- | --- |
| Mac / WW-005, WW-049 | Stock safe publication/revisions, New/Open, unnamed/elsewhere autosave, real panels/cancel/failed Save As, Revert, Close/Quit and restored windows; prior work/destination/dirty state preserved |
| Mac / WW-005, WW-049; Design controls | Actual visible **default-ON/configurable/OFF** controls, rapid edits/pending timers, independent checkpoint/recovery/cloud status, no false saved indicator |
| Mac / WW-005, WW-049 | Concurrent windows/processes and race-window conflicts; interrupted **library/project/index reconciliation** preserving semantic collections and both revisions |
| Mac / WW-005 | ≥100 actual interruptions at each relevant publication/fault boundary; disk-full, crash/power-loss/recovery distinction; migration preservation, malformed/newer packages and **newer-format edit/save prevention** |
| Mac / WW-005, WW-008 | Safe asynchronous snapshot/value handling; equivalent NSDocument/DocumentGroup tasks; native package/SQLite comparison remains open |
| Mac / WW-006, WW-049 | Separately consented named-provider/offline/two-machine and security-scoped sandbox/regrant/relink/denial/source-identity trials; source-download ON/OFF/cancel/retry with observed/unknown status |
| Mac / WW-007, WW-008 | macOS26 **runtime** and 16GB reference, 100-project/1,000-reference scale; target compilation/current RAM cannot substitute |
| Design / WW-007, WW-029; Mac native app | Actual File/Edit/View/Window menus/shortcuts, named undo, focus/selection/text-entry, numeric/non-drag alternatives, all core M1 keyboard/VoiceOver tasks, accessible blocked/conflict/offline/recovery/download states, 200% text/contrast/reduced motion; later separately consented pilot |
| Lead / WW-009, WW-010–012 | Explicit Brandon M1/production authorization **after** prerequisite outcomes or approved scope correction; no scaffold now; issue promotion only after completed planning/research |

## Actual reviews and integration disposition

| Review | Actual disposition / mode | SHA256 |
| --- | --- | --- |
| Mac technical-review.md (`<research-artifacts>/research/macos-document/experiment/technical-review.md`; local archive) | **Author technical evidence review**: “Accept the finite native callback/state/own-file subset, not a production lifecycle, adopted architecture, or cloud guarantee.” Not independent reproduction | `542fb3bebfb302d1a53b6a7fb4d4c88c36554a34d3593ed027943c046d629a45` |
| Design design-review.md (`<research-artifacts>/research/macos-document/design-review.md`; local archive) | **approve-with-limits**, actual read-only evidence review of technical review/selected compact/qualification sections; hashes unchanged, no prototype reproduction/UI tests; no material overclaim, rejection or lockout | `2fc85c0ebea0f59f26ea47c97d65a564f5db0724925de20fbdab614c4470749a` |

Design's verbatim review is retained unchanged; it is not polished or replaced by this synthesis. Its nonblocking accounting note is resolved by carrying BL09 without adding independent tests. Lead's acceptance is document/metadata coherence plus those actual review limits, **not a new empirical or renewed specialist review**.

Backlog mapping: WW-005/006/049 remain partial, with direct callbacks/local-coordination/plain-bookmark evidence only; WW-008 becomes narrowly partial for protocol availability compilation/plain bookmark, not signed distribution. WW-007 receives no status change because no library/UI/scale/index gate retired. Completed WW-001/002/004 remain documentary. No dependency/owner/criterion changed; graph fingerprint (ordered dependencies, sorted `[id, deps]` JSON SHA256) remains **`c6692502c03ab1f318f412ff67b4cec1a7edbe5c96cad63460d5916d30c10c43`**.

## Evidence appendix — exact retained artifacts

All links below are **local session artifacts**, not portable shipped application assets. Exact root:

`<research-artifacts>/research/macos-document/experiment/`

| Entry artifact / raw output | SHA256 / purpose |
| --- | --- |
| compact-evidence.json (`<research-artifacts>/research/macos-document/experiment/compact-evidence.json`; local archive) | `8ff65021ec8d21d2cdba88ae38a9575ec79d46e03a89b253114c8d2c619d03fc` · actual per-case APIs/operations/callbacks/errors/metrics/disk checks |
| qualification-summary.json (`<research-artifacts>/research/macos-document/experiment/qualification-summary.json`; local archive) | `9fa955fe99565308f4945189490c98e07bf260cce4ce344b5b02cf3147a12ff6` · 28 pass/0 fail, 37 case entries including nine exclusions, limits-array discrepancy retained |
| plan-v1.json (`<research-artifacts>/research/macos-document/experiment/plan-v1.json`; local archive) | `a69c68ec9a4fe9e3d49a400b9b669310e7951925f86d8beedc09048a61795706` · finite case protocol/gates |
| prequalification-manifest.json (`<research-artifacts>/research/macos-document/experiment/prequalification-manifest.json`; local archive) | `fd238154c23ef957a374f54d640f461abaa88fc1d909495c19c4098253c51caa` · prequalification chronology/frozen hashes |
| artifact-hashes.json (`<research-artifacts>/research/macos-document/experiment/artifact-hashes.json`; local archive) | `92419f8f3642871275416f56236f068bbd5aee7d4a456468c61cdbcb5d597594` · exact named source/build/fixture/raw/log paths and hashes; no recursive inventory needed |
| runs/qualification-c3/native-raw.json (`<research-artifacts>/research/macos-document/experiment/runs/qualification-c3/native-raw.json`; local archive) | `37289a5a72ddeea20d1a37a83dd75ffbc4ac5e470d138695048689eceff588e6` · Mac raw native event output |
| runs/qualification-c3/swiftui-raw.json (`<research-artifacts>/research/macos-document/experiment/runs/qualification-c3/swiftui-raw.json`; local archive) | `0aa49af6d6d3f0ed10884b76530b0eb7a8ed7b6a4663b08acfa48f3af85be507` · serial public snapshot output |
| runs/debug-c2/native-raw.json (`<research-artifacts>/research/macos-document/experiment/runs/debug-c2/native-raw.json`; local archive) | `530f998bcad21f80b53f18c27f691da16ffca5440e14acf6563a6232e53ef641` · retained dirty/no-checkpoint counterexample |
| logs/build-NativeExperiment-v1-c1.json (`<research-artifacts>/research/macos-document/experiment/logs/build-NativeExperiment-v1-c1.json`; local archive) / logs/build-SwiftUIAlternative-v1-c1.json (`<research-artifacts>/research/macos-document/experiment/logs/build-SwiftUIAlternative-v1-c1.json`; local archive) | `caff4289a0df71e7b98ccab5b0647f8baae7342cadc3f6cb7c5c9ecc96078380` / `cb99cb2555fb88e862355bc1971ce7b51f3ed820e657b2ce42ab460df1f21fb2` · retained invalid builds |
| logs/control-ConfigurationControl-v1.json (`<research-artifacts>/research/macos-document/experiment/logs/control-ConfigurationControl-v1.json`; local archive) / logs/control-AvailabilityControl-v1.json (`<research-artifacts>/research/macos-document/experiment/logs/control-AvailabilityControl-v1.json`; local archive) | `f2cad2733b1e4a0b2a1af81ebb504b4d3f6edcaa9e5ba149762b78f3023755c8` / `89fc5b2b1a175161f6e56f87f2fa3322233c9141c06800dfef1fb9f34a794e89` · expected negative compile controls |
| Mac actual raw technical review (`<research-artifacts>/research/macos-document/experiment/technical-review.md`; local archive) / Design actual verbatim review (`<research-artifacts>/research/macos-document/design-review.md`; local archive) | Exact hashes/modes above; raw agent outputs remain linked, not rewritten |

Reported qualified source hashes: **NativeExperiment-v3.swift** `37bf7c312cc4af84cc0a259a7a2c6644245a1a243515732d4fef9ed06c775ebd`; **SwiftUIAlternative-v2.swift** `72c5366c125081275b62e3703802c4984d23946035358cdb952fc8a0e8f8128b`. Fixture IDs/truth/hashes and full command arguments/stdout/stderr/return codes are retained in the named inventory/compact entry points; no source execution or duplication was needed for integration.

**Shutdown:** Mac reports all **14 bounded compiler/runtime invocations** joined without timeout, timers invalidated, Swift process exited and **0 remaining research processes**. Lead launched no research processes/services; document checks are bounded and completed. This is author/raw accounting, not a fresh system-wide process audit.

- **final-results (local archive):** `<research-artifacts>/research/macos-document/results.json`
- **mac-review (local archive):** `<research-artifacts>/research/macos-document/experiment/technical-review.md`
- **design-review (local archive):** `<research-artifacts>/research/macos-document/design-review.md`
- **compact (local archive):** `<research-artifacts>/research/macos-document/experiment/compact-evidence.json`
- **qualification (local archive):** `<research-artifacts>/research/macos-document/experiment/qualification-summary.json`
- **plan (local archive):** `<research-artifacts>/research/macos-document/experiment/plan-v1.json`
- **freeze (local archive):** `<research-artifacts>/research/macos-document/experiment/prequalification-manifest.json`
- **inventory (local archive):** `<research-artifacts>/research/macos-document/experiment/artifact-hashes.json`
- **native-raw (local archive):** `<research-artifacts>/research/macos-document/experiment/runs/qualification-c3/native-raw.json`
- **swiftui-raw (local archive):** `<research-artifacts>/research/macos-document/experiment/runs/qualification-c3/swiftui-raw.json`
- **c2-raw (local archive):** `<research-artifacts>/research/macos-document/experiment/runs/debug-c2/native-raw.json`
- **c1-native (local archive):** `<research-artifacts>/research/macos-document/experiment/logs/build-NativeExperiment-v1-c1.json`
- **c1-swiftui (local archive):** `<research-artifacts>/research/macos-document/experiment/logs/build-SwiftUIAlternative-v1-c1.json`
- **config-control (local archive):** `<research-artifacts>/research/macos-document/experiment/logs/control-ConfigurationControl-v1.json`
- **availability-control (local archive):** `<research-artifacts>/research/macos-document/experiment/logs/control-AvailabilityControl-v1.json`
