# Selected-Primary trusted read: RED contract (synthetic only)

This test-only unit does **not** authorize a source read. The current
`SelectedPrimarySourceReadIssuer.requireSourceReadAuthority` still throws
`trustedSourceOpenUnavailable`, `SpeechInference.infer` still refuses, and no
Backup, cut, speech or actual-episode open follows. The new
`SelectedPrimaryCheckedOpenRedTests` intentionally refer to
`expectedIdentity:` overloads that do not yet exist; a native compile failure
is the expected RED control, **not** a test pass. At `149654bd` a scoped package
JIT exited 1 on those absent overloads with zero tests run; the unhosted
`WaveWranglerTests` app-intent selector exited 65 with zero tests because
`EpisodeSetupModel` is app-only. This revision moves that coverage into the
existing app-linked `WaveWranglerHostedTests` target; no JIT has run on this
revised head. Keep ordinary unselected alignment decoding available through
its existing APIs; never treat that path as selected-source authorization.

## Checked-open contract

The selected record's user-confirmed `(show, source)` key and independently
observed fingerprint must reach `SourceContentIO.openForDecoding` via both
`SourceDecoder.run` (push) and `CursorWorker.make` (pull). The app, not a
caller-supplied URL or `SourceID`, binds this expectation to its current
selected-Primary intent. `SystemDecodingReader.make` must compare the **same
opened read-only descriptor**, including file-object identity, known
size/mtime and volume evidence, against the expected source and fresh
metadata **after** `open`/access-mode check/`fstat` but **before**
`AudioFileOpenWithCallbacks` or any byte read. An absent field or mismatch
refuses; do not read a header first and recheck afterward. Retain that FD for
callbacks and post-decode staleness checks. Fingerprints are evidence for a
specific opened file, not standalone consent or a reusable capability.

The synthetic WWDecode RED selectors are:

| Selector in `SelectedPrimaryCheckedOpenRedTests` | Required result |
| --- | --- |
| `pathReplacementBeforeParserRefusesWithoutHeaderReads` (different/same size) | Atomic replacement between preflight and open refuses `sourceIdentityMismatch`; the selected-Primary opener runs, **zero** header-read callbacks, Backup untouched. Same-size replacement must still fail on file-object identity. |
| `missingDescriptorIdentityRefusesBeforeParser` | Unknown volume evidence refuses before any header read. |
| `pushAndCursorPathsCannotBypassCheckedOpen` (push/cursor) | Both checked entry points receive the **correct Primary identity**, then replace its path with a different same-size file inside the opener. Both must open the selected path, refuse the wrong descriptor before a sink or header read, and leave Backup untouched. Passing a Backup fingerprint to preflight instead is not this test. |
| `selectedPrimaryChannelUsesOneCheckedDescriptorAndNeverOpensBackup` | Generated 16 kHz two-channel Primary yields exactly **32,000** channel-1 source frames from one checked descriptor; generated Backup is never opened or modified. |
| `cancellationAtLastWindowReadCannotPublishCheckedPCM` | Generated final-window read cancels the decoder task; checked PCM is never returned and the reader closes. |

The existing `VerifiedSourcePCMWindowTests` cover negative/overflow starts,
out-of-bounds channels and incomplete windows at the decoder primitive, not
app authorization. They must remain alongside the RED selectors. All fixtures
are generated under temporary directories; no user recording or model is used.
The opener/read observers are DEBUG-only gateway hooks, not alternative content
paths. A newly introduced positive selected read must use the existing
WWSources scope/metadata checks and the sole WWDecode
`SystemSourceContentIO` content gateway.

## App intent coverage and issuer cases required before positive release

The current app has no injection seam for an open registered `ShowDocument`,
Setup window, keyed inventory/access read and the checked decoder in one
synthetic test; inventing a caller-owned fake receipt would test the fake, not
the app. An independent reviewer must agree on that private seam before the
separate implementation/JIT. The app-hosted
`WaveWranglerHostedTests/EpisodeOpenShowBindingTests.swift` now exercises the
real Setup model: confirmed channel-1 Primary row/speaker, Backup and
mismatched row/speaker/invalid channel/provisional role or assignment refusal,
selection-away-and-back generation, source removal/restoration,
alignment/document value ABA generation, and missing accepted map and window
refusal. Its existing issuer test also cancels before source open. These are
**intent and generation/refusal tests** (pending an exact-head hosted JIT),
not an issued source grant, access-store ABA test, checked app read, or proof of
positive publication. The app issuer still returns `Never` and throws
`trustedSourceOpenUnavailable`; there is no test-only injection point for an
actual registered document/window plus access store and decoder. Adding
success-shaped fake issuance here would bypass the very boundary under test.

An independent Fact Checker approved **tests-only RED preparation**, not
positive issuance. `WaveWranglerHostedTests/SelectedPrimaryIssuerRedTests.swift`
now specifies the missing internal app-owned `readCheckedPrimaryWindow` bridge
and its `SelectedPrimaryPCMWindow` result. This is intentionally a compile RED:
`requireSourceReadAuthority` still returns `Never`. The hosted fixture refuses
to touch `SetupEngineProvider.store` or create bookmarks unless
`PersistenceEnvironment.isUITestRun` was set at app launch. It registers an
actual `ShowDocument`, runs `makeWindowControllers`/`showWindows`, waits for the
key Setup window's real registered controller, and selects its Primary row and
speaker. Generated 16 kHz WAV Primary and Backup have independent keyed
access records, metadata, and accepted-map placements; Backup metadata survey
is permitted, but its content descriptor must never open.

The RED bridge takes only the live document, live window, and source-frame
start; the app derives selected source, channel, access record and expected
identity itself. The future internal result exposes a checked channel, source
frame range and 32,000 samples only after the descriptor-gateway check and
last publication revalidation. `VerifiedSourcePCMWindow` is package-scoped:
an app client cannot call or return that type directly, and cannot manufacture
an unverified result. DEBUG-only `debugPhaseObserver` (after authority capture,
before descriptor open, before publication) and `debugSourceOpenObserver`
observe phase/source ID without supplying a URL, identity, receipt, PCM or
alternative read path. The source-open observation must be emitted from the
single content gateway for **every** opened source, not from an intent-only
preflight. Phase observers may suspend, mutate app state/access records or
cancel the current task to assert refusals at those boundaries.
The RED issuer owns a monotonic actor-instance access-revision witness; an
equal-looking remove/restore must refuse even if the cached record matches.
Neither that witness nor these tests prove freshness against other store
instances/processes or external OS scope revocation (#430).

The hosted RED matrix injects selection row **and** speaker away/back,
access-record remove/restore, and accepted-map **and** document mutation/undo
at both `beforeDescriptorOpen` and `beforePublication`. Each case must reach
its selected phase and refuse despite restored values: before-open cases
observe zero descriptor opens; before-publication cases observe exactly one
Primary open and zero Backup opens. Cancellation has the same paired
before-open/before-publication count and must throw `CancellationError`.
These phase/count assertions prohibit an earlier generic refusal from
masquerading as a passed stale-authority recheck.

This hosted RED suite has **not** had native compilation or GUI execution:
that requires a separately authorized JIT/GUI lease. Its intended compile
failure on missing app-private symbols is not a test pass and does not change
the refusal-only production issuer or authorize Backup, inference, or edits.

Before a positive release, add these **behavioral** RED cases against the
reviewed private seam (not just source-text assertions):

| Planned selector | Fault injection / assertion |
| --- | --- |
| `selectedPrimaryRowAndSpeakerOnly` | Generated Primary (channel 1) and distinct Backup; source row and selected speaker agree; Backup row, other speaker, provisional role/assignment and negative/out-of-range channel refuse. No Backup content open. |
| `selectionAndInventoryABARefuse` | Change row/speaker away and back, and replace the keyed inventory/access record with equal-looking values; old intents/revisions refuse before open and before publication. Access remove/restore must not regain old authority. The actor-instance revision is a local invalidation witness, **not** proof against other store instances/processes. |
| `acceptedMapAndDocumentABARefuse` | Change accepted map/occurrence/epoch; mutate/undo document, Save As, close/reopen and change publication bytes back to an equal-looking model. All stale captures refuse after suspension and at publication. |
| `cancelAtOpenAndBeforePublicationRefuses` | Cancellation at descriptor open and after decode discards results; no partially published PCM or inference call. |
| `boundedSelectedPrimaryWindow` | A freshly checked Primary alone yields exactly 32,000 finite samples, matching channel 1 at source frames `start..<start+32_000`; invalid channels, overflow and out-of-map windows refuse. |

At each suspension boundary recheck the actual registered window/document
owner, selected episode row/speaker/Primary channel, keyed inventory and
selection revision, device-access actor-instance revision, accepted map/source
revision, document origin/publication/mutation generation and cancellation.
Before publishing, verify that the decoded descriptor identity is the selected
source and that all captured authorities remain current. No substituted
recording or success-shaped fallback is permitted.

External uncoordinated writers and OS scope revocation remain separate
documented risks; these tests assert the normal wrong-header-read boundary,
not a universal zero-revoked-open guarantee. No full/GUI gate, positive speech
grant or production acceptance is claimed until independent source-boundary
review and a separately authorized native JIT.
