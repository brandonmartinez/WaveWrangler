# WW-027 prospective word/proposal evaluation freeze

**Status:** prospectively frozen metric/split rules v1, synthetic scorer calibration only (2026-10-08). Refs #21 #32. The engine, model and permissioned corpus freeze are still incomplete; no disjoint holdout has run. `WWWordEvaluation` is an inert, pure scoring adapter, not an edit/acceptance API. A clean, pushed protocol-containing commit and independently pinned, actually provisioned local engine must precede any holdout. Holdout needs independent permissioned annotation and explicit scope/consent for the selected Primary, with aggregate-only published evidence. Do not turn synthetic results into claims of actual-media accuracy, 98% precision, or protected-cut acceptance.

## Frozen population, truth and matching

- Eligible reference words are independently transcribed lexical English words on the authorized, explicitly confirmed Primary channel within a single identified source occurrence and declared epoch, including contextual fillers, meaningful filler-like words, intelligible low-volume and overlap words. Two independently annotated reference boundaries (start and end, in milliseconds relative to the same source occurrence) are mandatory per eligible word. A canonical placement is unique by occurrence/epoch, normalized lexical identity and exact start/end boundaries: assigning another reference ID or stratum to the same placement is invalid truth and cannot add denominator observations or proposal targets. Truly repeated words remain distinct when their source position or occurrence differs. Annotators resolve disagreements before scoring, blinded to engine output. Exclude only predeclared untranscribable/nonlexical spans, annotation-disputed boundaries, unconsented sources/Backups and unsupported source/epoch ranges **before** inference; report excluded counts/reasons by stratum. Never remove an eligible word because the engine omitted it, lacked timing, or abstained.
- Strata are disjoint and assigned from reference truth before inference in priority order: meaningful-token use, overlap, noise, long clean (source segment >=5 min), short clean (<5 min). No episode, source family, sample or source occurrence may appear in both calibration and holdout. Minimum holdout per stratum: 50 eligible words = 100 boundary observations and 40 emitted proposals; totals >=500 eligible words/1,000 boundaries and >=300 emitted proposals. The priority rule avoids counting a noisy overlapping word twice. If a class cannot fill its minimum, fail the prospective envelope rather than reclassifying it after seeing outcomes.
- Match observed words to reference words once, one-to-one within the *same* occurrence/stratum with case-insensitive lexical identity after trimming surrounding whitespace/punctuation (internal punctuation remains significant), preserving monotonically increasing word order. Independent annotators assign stable matched-reference IDs blinded to timing and proposed cuts; no nearest-timestamp match, speaker fallback, or backup retargeting. Unmatched, wrong-occurrence and wrong-text outputs are hallucinations/match failures, not timing credit. The adapter checks ID and canonical-placement uniqueness, text, occurrence, stratum and order; duplicate canonical truth placements are hard errors before scoring regardless of their IDs or strata. Duplicate non-nil matched-reference-ID claims are also hard errors even if a claim has mismatched text/occurrence/stratum, as are reversed reference matches.
- Only boundaries with independent validated timing evidence and current source-frame/proxy-chunk-to-source, occurrence/epoch and accepted alignment-map mappings enter the adapter as `supported`. Raw engine word time, recognition confidence, neighboring word time, an interpolated/guessed time, or out-of-map/gap time must be `unsupported` or `missing`. Both start and end must exist for a proposal to be timing-supported. Recognized-word confidence, when actually supplied, is recorded separately with engine/units and NEVER substituted for boundary evidence.

## Locked calculations and thresholds

Timing denominator = **two times all eligible reference words**. Supported uniquely matched start/end boundaries contribute individual absolute errors; omitted and unsupported eligible boundaries stay in the denominator as coverage failures. Report each stratum and overall eligible, supported, omitted, unsupported and hallucinated counts, coverage, nearest-rank matched-boundary p95 (`sorted[ceil(.95*n)-1]`) and maximum error; p95 is undefined if no supported matches. Minimum supported timing coverage: **>=95% overall and >=90% in every stratum**, overall supported-match p95 absolute error **<=100 ms**, with >=1,000 reference boundaries and >=100 per stratum. A low p95 on a selected subset cannot pass insufficient coverage.

Independent truth marks contextual removal **targets** (not permission to cut). Each target's annotated word list must resolve entirely to canonical reference placements in one occurrence and one stratum, must be chronological, and the same ordered canonical word sequence cannot be registered under another target ID. Re-ID aliases cannot create additional targets or precision matches. Every *emitted* candidate proposal on an eligible selected-primary occurrence enters the precision denominator, including hallucinated, duplicated, unsupported-boundary, unsafe, and incorrect-context proposals; a correct proposal uniquely matches an independently annotated target/ordered word list in its stratum with both boundaries validated. Repeated proposals for one target count only the first as a true positive; later ones are false positives. A proposal with an unsupported/unmatched word is a false positive and fails the separate zero-unsupported-proposals rejection gate. Report emitted, true/false positive and unsupported counts by stratum; abstained counts separately, precision `TP/emitted`, **one-sided Wilson 95% lower bound** with `z=1.6448536269514722`, and secondary recall `unique TP / all eligible truth targets`. Abstentions are explicitly counted separately, never silently removed from the eligible emitted-proposal denominator once emitted. Gates: >=300 emitted, >=40 each stratum, precision >=98% **and** Wilson lower >=95%; undefined ratios fail. No calibration retuning against holdout.

## Split, provenance and non-statistical gates

Reserved split seeds (no seed is used by the present deterministic unit fixtures):

| Disjoint stratum | Calibration seed | Unused holdout seed |
| --- | --- | --- |
| Short clean | `0x27010001` | `0x27020001` |
| Long clean | `0x27010002` | `0x27020002` |
| Noise | `0x27010003` | `0x27020003` |
| Overlap | `0x27010004` | `0x27020004` |
| Meaningful token | `0x27010005` | `0x27020005` |

Pin generator/truth recipe and evaluation test/source-tree SHA, independent permissioned truth manifest, corpus split and stratum counts, chosen engine executable/build, decoder/vocabulary/options, locale, model/weights/transitive hashes/licenses, and signed/managed system-asset identity/known limitations in a dated clean freeze record **before first holdout invocation**. Any engine, model, license status, locale, asset revision, format interpretation or truth/threshold change invalidates this prospective freeze and requires a new revision and fresh disjoint seeds; preserve prior failed results, no silent rerun.

Analysis remains selected-Primary-only, backups untranscribed. Explicit Backup activation changes primary-assignment revision and requires new analysis/review, never token/proposal retargeting or duplicate proposals. Each word/proposal provenance retains stable token ID, source ID/channel and occurrence ID, source-frame span/rate, epoch/group, proxy rate/chunk and invertible proxy-to-source mapping, current accepted alignment revision, transcript/model/decoder/locale/source/derived-asset revisions and timing evidence status. Missing times stay absent. Canonical user text/timing corrections with author/provenance/revision/undo survive reanalysis; split/merged words lose timing until independently revalidated. All upstream changes stale dependent suggestions/decisions until reconciliation.

This statistical gate is **separate** from WW-028/WW-030: a human must review and accept each cut, and current source/map/epoch/occurrence and *every affected lane* (including Backups, silence, other speakers, fades and common-map footprint) must have known safe backing/protection. No protected/meaningful/other speech may be lost; unknown coverage means block/review/abstain. Neither this scorer, high precision, a default Shorten mode, nor recognition confidence grants a cut, lift, fade, preview or export. Protected-edit listening/undo/common-map validation remains mandatory independently.

## Generated-PCM token API characterization (preparatory, not holdout)

The private `ww-tiny-pcm-probe` on the stacked #388 branch reports **aggregate
token observations only**, from two in-memory generated-tone passes on a
separately validated local model: the existing token-timing-disabled pass and
an experimental token-timing-enabled pass. DTW remains off in both. Both
passes must succeed; the second pass has its own `enabledInferenceSeconds`.
The CLI emits one JSON object with `tokenTimingDisabled` and
`tokenTimingEnabled`, each bearing `mode`, `provenance:
"experimental/unsupported"`, token/text-token counts, absent-or-invalid/
experimental text-token counts and counts of leading/internal whitespace and adjacent
unseparated token surfaces. These are token-text-shape observations, **not**
word segmentation or source-frame timing. `wordTimingAvailable` is false,
`supportedWordBoundaryCount` is zero, and no word-frame bounds or recognition
confidence are emitted. The earlier whitespace-derived `whitespaceWordCount` remains a
rough diagnostic, not evidence of validated words.

The pinned v1.6.2 `whisper.h` labels token timestamps experimental and warns
not to read `t0/t1` when they were not computed (`upstream/whisper.h:129-145,
492-497`). Decoder tokens initialize `t0/t1` to -1
(`upstream/whisper.cpp:5150-5152,5266-5269`). With token timing enabled,
upstream can fill missing intervals by proportional voice length and adjust
them for overlap and voice activity (`upstream/whisper.cpp:6759-6962`);
`split_on_word` only affects wrapping when `max_len > 0`, not a word-time
API (`upstream/whisper.cpp:6120-6128,6165-6171`). The probe never requests
DTW (`upstream/whisper.h:119-120`). Nonpositive/reversed/partly missing
token intervals and all disabled-mode intervals classify absent; other
enabled-mode intervals classify **experimental/unsupported**, even when
numbers are present: the public API cannot identify which were filled or
adjusted. Segment timestamps, whitespace counts, token probabilities and
these experimental intervals cannot be promoted to supported source-frame
word boundaries or cuts. The no-model synthetic shape/classification tests
do not run the engine or validate transcription. The frozen >=1,000 reference
boundary and >=300 proposal gates and approved-media/offline validation
remain unrun.
