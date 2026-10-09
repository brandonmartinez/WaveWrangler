# Selected-Primary trusted read: RED contract (synthetic only)

This test-only unit does **not** authorize a source read. The current
`SelectedPrimarySourceReadIssuer.requireSourceReadAuthority` still throws
`trustedSourceOpenUnavailable`, `SpeechInference.infer` still refuses, and no
Backup, cut, speech or actual-episode open follows. The new
`SelectedPrimaryCheckedOpenRedTests` intentionally refer to
`expectedIdentity:` overloads that do not yet exist; a native compile failure
is the expected RED control, **not** a test pass. No native test/build has run
for this unit. Keep ordinary unselected alignment decoding available through
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
| `pathReplacementBeforeParserRefusesWithoutHeaderReads` (different/same size) | Atomic replacement between preflight and open refuses `sourceIdentityMismatch`; **zero** header-read callbacks, Backup untouched. Same-size replacement must still fail on file-object identity. |
| `missingDescriptorIdentityRefusesBeforeParser` | Unknown volume evidence refuses before any header read. |
| `pushAndCursorPathsCannotBypassCheckedOpen` | Both decode and cursor checked entry points refuse wrong descriptor before a sink or header read. |
| `selectedPrimaryChannelUsesOneCheckedDescriptorAndNeverOpensBackup` | Generated 16 kHz two-channel Primary yields exactly **32,000** channel-1 source frames from one checked descriptor; generated Backup is never opened or modified. |

The existing `VerifiedSourcePCMWindowTests` cover negative/overflow starts,
out-of-bounds channels and incomplete windows at the decoder primitive, not
app authorization. They must remain alongside the RED selectors. All fixtures
are generated under temporary directories; no user recording or model is used.
The opener/read observers are DEBUG-only gateway hooks, not alternative content
paths. A newly introduced positive selected read must use the existing
WWSources scope/metadata checks and the sole WWDecode
`SystemSourceContentIO` content gateway.

## App issuer cases required before positive release

The current app has no injection seam for an open registered `ShowDocument`,
Setup window, keyed inventory/access read and the checked decoder in one
synthetic test; inventing a caller-owned fake receipt would test the fake, not
the app. An independent reviewer must agree on that private seam before the
separate implementation/JIT. Write these **behavioral** red cases against it
before enabling a positive return (not just source-text assertions):

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
