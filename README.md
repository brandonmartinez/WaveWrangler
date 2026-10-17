# WaveWrangler
Local-first macOS multitrack podcast alignment and editing

Native macOS multitrack podcast preparation: local audio processing, referenced media, cloud canonical projects.

## Library and episode editors

Select a show in **Library** to browse and manage its episodes. Create, rename, reorder, or delete
episodes there, and edit show or episode information without opening an editor.
Double-click an episode or choose **Open Episode** to edit it in a dedicated window. Multiple
episodes, including episodes from different shows, can remain open together. Opening an already-open
episode brings its window forward; **Open Episode in New Window** creates another view.

Editors have no episode selector. Each stays bound to the episode it opened; deleting that episode
shows an unavailable state rather than switching the editor to another episode. Windows belonging to
the same show share its document, Save/autosave state, and Undo history. Closing an episode window
does not discard a show that is still being managed in Library; **Close Show** closes that show
through the normal unsaved-changes decision.

## Visual alignment

Import recordings in **Setup** to review device groups, epochs, and speaker/channel
assignments. A new import has provisional file identity: choose **Confirm original** for each
unchanged local source before decoding or playback. A changed original must be reviewed through
**Relink Source** instead. Sources remain referenced in place and are never modified.
Device-local records left by sources removed from the show do not block confirming a newly
imported source; an original still used by another source in the show remains unavailable.

In **Alignment**, the shared timeline is the primary editor. **Refresh audio** loads bounded
measured waveform windows on one seconds-based ruler. **By speaker** is the first and default layout,
grouping lanes by assigned speaker across recorders. **By recorder** groups lanes by recorder group.
Unassigned recordings remain under **Unknown speaker**. **Overlay** always combines enabled
recordings by speaker on the same scale. Changing layout does not change timing, recorder-group
membership, or which recordings are shown and heard. Use the lane
checkboxes, overlay recordings list, or **Recording** inspector to choose which groups and tracks
are shown and heard. Select a recording to make its recorder active for overlay dragging.
Choose **Place groups at source time**
to accept a first manual placement without running
acoustic analysis. **Normalize view** scales each recording's displayed peaks within its measured
tile (including zoomed-out main lanes); it does not change audio, playback, or saved
timing. Up to eight bounded measured tiles and their projected strokes are cached in memory;
adjacent tiles share the same viewport without rebuilding their paths on each pan. A changed
episode, source, or verified alignment clears them.

Open a recording's settings button to choose its **Speaker** and **Channel** in the
**Recording** inspector, then use **Align…** beside a non-reference track. These choices edit the same
episode Setup assignments (one speaker and one stated channel per source), with Undo and
normal document saving; they are not temporary match settings. Choose a reference
recording from the menu if several already aligned tracks share that speaker. The reference
recorder itself cannot be matched as a target. State known channels on both sides first:
unknown or out-of-range channels cannot be matched. A measured mono source has only one
possible channel: assigning its speaker also states channel 1, while a previously assigned
mono source with an unknown channel offers **Use mono channel 1** instead of a channel menu.
An eligible match compares only that
speaker's stated channels and proposes the **target recorder group's**
timing, so its other tracks move with it. You can then match another speaker from the newly
aligned recorder to a third recorder without moving either already aligned group. Unrelated
speakers are not mixed to manufacture a match. Multichannel files currently have one assigned
speaker channel per source; split or import separate sources if independent speakers need their
own assignments. Selected-speaker matching streams each complete channel into a compact spectral
fingerprint, finds shared passages across the whole reference, then precisely checks distinctive
passages distributed over the overlap to fit offset and drift. Fine matching filters low-frequency
rumble, tolerates opposite waveform polarity, and uses the coarse drift estimate to speed-compensate
short analysis snippets before comparing them; originals are never filtered, stretched, or inverted.
These analysis hints do not approve timing or relax the ambiguity and coverage checks.
**No initial anchor or manual placement is required.** The first scan can take a while; unchanged channel fingerprints are cached
locally for reuse. Unequal file lengths do not require a percentage setting. This candidate supports
channels up to two hours and needs at least twenty seconds of shared audio; ambiguous content or
insufficient distributed evidence can still require a different speaker or manual anchors.

The analysis reports the measured offset, drift in ppm, covered interval, eligible
windows, peak evidence and residual, or a refusal for silence, ambiguous/periodic peaks,
inconsistent drift, discontinuities or unavailable sources. These are **not probabilities or
proof of clock accuracy**: different microphone distances can imitate an offset. Nothing is
automatically applied. Review the proposal or refusal directly under the selected waveform,
using **Show proposed alignment** to toggle a dashed teal ghost of the proposed measured interval
in the main lanes or speaker overlay. The ghost moves every loaded track in the affected recorder
epoch, without changing saved timing, playback, anchors, or extending beyond measured coverage.
Then choose **Accept measured interval** to create an
undoable, verified manual decision; rate-aware playback corrects that mapped interval's
clock rate (not pitch-preserving time stretching) without altering the original. Outside it,
audio stays unplaced. **Extend to whole epoch…** is a
separate, warned human decision to extrapolate its rate and offset into unmeasured audio, not a
new confidence claim. Whole-track feature indexing is not precise verification of every intervening
frame, so brief edits between checked passages can be missed. A quiet stretch between consistent
matches can remain in the proposal only when both decoded recordings measure silence there; this
does not prove that no audio is missing. One-sided active-audio gaps, unrelated windows, and declared
recorder restarts still refuse or stay separate. Accepting a proposal
records visible evidence markers at its first and last reliable windows, not a clock approval.

For software/network recordings whose delay changes within a take, select the target waveform and
choose **Adaptive review…**. This experimental path measures overlapping local
windows throughout the shared audio instead of forcing one offset/rate over the entire file.
Dashed teal waveforms and clock icons show locally supported timing runs for **only that file**;
uncertain transitions, silent/ambiguous regions and unmeasured ends are not filled or extrapolated.
Choose **Accept supported file timing…** to save a file-local correction and enable pitch-preserving
playback. Review the confirmation carefully: **unsupported intervals are silent**, including
unverified gaps and ends. This is not yet a reliable whole-track repair for every software recording.
One shared multichannel processor applies the curve to every channel in that file; sibling files
and original media remain unchanged. Blue clock icons mark applied timing. **Remove adaptive file
timing** and native Undo/Redo restore earlier timing without discarding decoded waveform bins.
Full-length review reports progress and can be cancelled without accepting any partial timing.
Listening and derived aligned audio use the same bounded, pitch-preserving audio tiles, not the
ordinary pitch-changing affine resampler. Source-region processing origins and shared crossfades
avoid restarting audio phase at playback-window boundaries. Remove file-local corrections before
editing recorder-group timing. Shows now use schema 4; older shows require the normal backed-up
migration before saving.

In a recording's inspector, **Prefer this recorder as timing reference** marks an explicit preference
for a reliable source, such as your main hardware recorder. Multiple recorders may be preferred.
An already accepted timeline reference stays fixed; otherwise preferred eligible recorders rank
before speaker primaries, then the normal source order. Among already timed matching speaker
sources, preferred recorders rank first. Device brands and filenames never certify clock quality.

Click a covered point on an already timed speaker track, choose **Mark reference point**, then
click the matching point on the same speaker's track in another recorder and choose **Link to
reference marker…** in the inspector. Repeat at a second point and **Apply anchors** to fit offset and drift;
the marker pairs are staged, not saved timing, until you apply them. Zoom into the waveform
for precise clicks. Manual numeric editing remains available when no matching reference
audio exists. Accepting one match never makes other proposals playable.
If a previously accepted map reports a changed source dependency, alignment refuses rather
than silently rebasing old timing. Confirm the original in Setup and restore it, or choose
**Start fresh alignment…**, confirm that the accepted timing should no longer be used, wait
for the show to save, and place the current groups again. The old map remains in history and
the change is undoable; restoring the old selection cannot make a genuinely changed source
current. Tiny metadata timestamp differences within the source-identity comparison tolerance
no longer change newly recorded revision keys.
For a recorder with restarted/overlapping source-time epochs, only its first
placeable epoch is mapped initially; place later epochs explicitly using **Advanced timing**.
Select a track and drag its waveform, use the inspector's 10 ms nudge buttons, or type **Group move (ms)** to move all
mapped epochs of its recorder together in one undoable revision. A drag shows its shift in seconds and commits on
release; the offset change is the pointer distance divided by the visible waveform width, multiplied by
the visible span. Further drags add or subtract from the saved offset. Zoom to a shorter span for fine
adjustment, or use the nudges. Positive moves place that recorder
later. Unplaced audio is dashed, not implicitly synchronized. Enable/disable a recorder or track
to show/hide and hear/mute it; speaker lanes have stable colors, with gray for unknown speakers.
Changes to accepted timing save in the show document and can be undone or redone.

**Play** mixes only confirmed enabled sources on the stored aligned map, starting at the shared
playhead; **Pause**, **Stop**, click-to-seek, and typed aligned playhead are available. Unsupported
or uncovered regions are silent. Playback reads witnessed five-second windows and may briefly
buffer between windows; a source or map mismatch stops playback rather than substituting audio.
Use the compact zoom and lane-height sliders beside **Fit timeline** above the ruler.
Drag the playhead flag to seek, drag empty ruler space to pan without moving the playhead,
or pinch the ruler to zoom around a time point. All recorder lanes share that viewport.
**Fit timeline** shows the full episode in the main tracks; zoom in or type a time to load
a distant measured window. The playhead is ready for **Play** afterward; panning does not play audio or change saved
timing. Cached adjacent tiles translate without rebuilding their paths. An uncached section may
take a moment to display; unavailable reads are reported rather than silently replaced.
Windows outside a recording show its explicit unavailability;
navigation remains within the supported minus-24-to-plus-24-hour aligned range. The inspector's
**Compare Aligned Audio** control plays up to five seconds of reference/selected
audio in separate channels for an internal listening check, not an export or cut authorization.

There is no secondary episode overview. Zoomed-out main lanes use at most 2,048 measured amplitude
bins per recording; precise windows remain available when zoomed in. Timing-only acceptance and
Undo/Redo retain source-coordinate bins and reproject them after save/source verification instead
of clearing and decoding every lane again. Changed sources still invalidate the display, gaps
stay absent, and audio outside an accepted measured interval remains visibly unplaced, not playable.
A full-scale scan supports up to 24 source hours per recording; exact navigation remains bounded
to minus 86,400 through plus 86,400 aligned seconds without changing stored timing.

This is an alignment workspace, not a DAW or complete editing workflow. PCM recordings support
exact random-access waveform windows and aligned listening throughout an episode, without decoding
the preceding hours. Other codecs retain the first-10-source-minutes limit (including inverse map
offsets); later windows are explicitly refused until exact seeking is established. No persistent
waveform cache is created; when a wider tile reaches a codec preview limit, a narrower exact
window is tried before reporting unavailability. Real local transcription and protected filler-word editing remain
separate, incomplete MVP work.

## Planning

- [Start M1: copyable Squad kickoff](docs/planning/kickoffs/m1.md) · [milestone execution runbook](docs/planning/milestone-runbook.md)
- [Live GitHub milestone/issue index](docs/planning/github-backlog.md) · [machine-readable mapping](docs/planning/github-backlog.json)
- [Public sanitized-provenance index](docs/planning/publication-provenance.json)
- [Product brief](docs/planning/product-brief.md)
- [Accepted decision ledger, historical research/reviews, and future experiments](docs/planning/research.md)
- [Prioritized, dependency-aware backlog](docs/planning/backlog.md)
- [First foundation batch: frozen holdout, native specification and remaining gates](docs/research/foundation-spikes.md) · [evidence mirror](docs/research/foundation-results.json)
- [Native document spike: actual callbacks, policy boundaries and remaining gates](docs/research/native-document-spike.md) · [compact evidence mirror](docs/research/native-document-results.json)
- [Windowed document UI batch: closed, partial/failed/blocked evidence and actual reviews](docs/research/windowed-document-spike.md) · [compact results](docs/research/windowed-document-results.json)
- [Project format/recovery: full canonical work, actual read-only review and candidate limits](docs/research/project-format-recovery.md) · [sanitized-provenance results companion](docs/research/project-format-recovery-results.json)
- [Parallel research reconciliation and owned remaining gates](docs/research/parallel-readiness-reconciliation.md)
- [Native policy/library evidence](docs/research/native-policy-library-readiness.md) · [waveform estimation and retained clock failure](docs/research/waveform-clock-render-readiness.md) · [source reconstruction/speech choices](docs/research/source-reconstruction-speech-readiness.md) · [native review interaction contract](docs/research/native-review-contract-readiness.md)

## Accepted direction — 2026-10-04

[Q01–Q10 are answered](docs/planning/research.md#approval-questions); the twenty decision facets distinguish approved policy from unmeasured implementation:

- One durable show/project library with multiple episodes; source media referenced in place, portable copies deferred. **Cloud canonical documents are MVP**, with measured provider safeguards. Autosave **ON/configurable/off**, plus explicit Save; in-memory periodic saves are a research suggestion, not architecture or provider atomicity.
- Evaluate **macOS 26+, Apple silicon only, English only**; 16 GB initial reference, not proven minimum, 8 GB later. Fair native Speech/local Whisper comparison; SpeechTranscriber eligible, not selected. Signed/notarized **direct download first**, App Store first launch deferred; artifact-specific signing/privacy/license clearance still required.
- Human-accepted synchronized shortening is MVP default: **“Shorten when safe and by default, but allow the user to edit that point and choose a different method”**. One common map on every preview/export track, never independent ripple. Editable protected-overlap speaker-lift alternatives, undo/history/partial inverses/crossfades; overrides cannot waive meaningful/protected/other speech, uncertainty means manual/review/abstain.
- **DAW-neutral** zero-origin speaker stems with identical rate/map/duration/rounded boundaries/silence padding plus an editable reconstructive cut record/source references/recipe/asset requirements and demonstrated restoration/regeneration when assets are available. Stems alone cannot restore removed audio; no required REAPER/native session or forced copies. Configurable **48 kHz/24-bit PCM WAV** default, feasible detected source settings/prefer 48 kHz, coherent mixed-rate output. Broad WAV compatibility is a goal, not universal fact; native adapters later.
- Common macOS imports subject to validation: WAV/BWF/AIFF/CAF/AAC-M4A/MP3/optional supported FLAC are candidates, not promises. Priming/padding/time maps/rates/bit depth/channels/errors/build licenses need evidence; native decoding preferred if supported by evidence.
- Automatic **source downloads ON/configurable/off**, accessible status/progress/unknown/offline/cancel/retry/native coordination and immutable originals. Default-OFF metadata fixture trials are separate tests, not product default or a generic provider classifier.
- Numerical quality/accessibility goals provisionally approved; controlled calibration before holdout, explicit approval for weaker gates, including cloud and shortening coverage. Compare AppKit NSDocument + SwiftUI with SwiftUI document lifecycle for native/cloud-safe saves/autosave/recovery; no framework/file/package/JSON/SQLite choice adopted.

## Current delivery policy - user-directed 2026-10-04

GitHub issues and six milestones are the operational backlog. The 2026-10-10 user decision supersedes
the earlier Squad/orchestrate delivery process: direct implementation now prioritizes saved manual
alignment and playback; export and speech/cut work come later. File management
and numeric tables alone do not satisfy the MVP. Existing M1/M2 evidence is retained; M3 and the full
MVP are not complete. **First audio handoff is cleaned-track M4; no uncut M2 handoff.** Public
signed/notarized distribution, actual macOS26/16GB and broader device/participant qualification are
separate Release work, not pre-app gates.

This publication changes documents/context only. Pasting [the M1 kickoff](docs/planning/kickoffs/m1.md) grants M1 engineering, scoped dependency restores, isolated worktrees/branches, commits/push, independently reviewed merges and issue updates. WW-009 records contracts/evidence/risks, not another generic approval. Dependencies gate accepted outcomes, not safe preparatory coding. Immutable sources, cloud canonical durability, protected speech, offline/privacy and essential native keyboard/accessibility are never deferred. Recording/model/provider/native/GUI/signing/external publishing consent remains exact-scope; source-download ON is not agent sample permission.

Later decisions supersede the historical no-issues/research-only statements below without rewriting their evidence. Current graph: **52 stable IDs / 203 acyclic edges / 49 open issues**; WW-001/002/004 stay completed history. WW-003/008 are staged M1; WW-041 now follows WW-042 in Release; new WW-052 holds broader qualification. [Runbook](docs/planning/milestone-runbook.md) explains completion, review, concurrency and next-session handoff.

**Public provenance:** published research JSON companions are pointer-redacted and **NOT byte-identical to archived originals**. [Original versus published hashes](docs/planning/publication-provenance.json) are separate; measurements, pins, artifact hashes and failed controls remain unchanged. Local evidence placeholders are descriptive, not accessible repository files.

## Historical evidence snapshots

**Latest finite integration — 2026-10-04: four parallel research lanes and actual Lead reconciliation complete.** [Dedicated reports and parent adjudication](docs/research/parallel-readiness-reconciliation.md) accept evidence/planning with limits, not architecture or production. Mac adds 53 local cases and one genuine windowless queued OFF/ON pair; Alignment processes actual generated waveforms but **falsely accepts 2/6 acoustic negatives, failing its WW-016 candidate gate**. Pipeline regenerates/restores original-source assets in seven cases, not quality-qualified SRC/DAW support; Design supplies a review contract and 24 pure-state scenarios, not native accessibility approval.

**New load-bearing limits:** a bookmark can resolve a same-name replacement; the native OFF probe's nil no-publication callback is not safe Close/Quit adoption; merged fades need final-footprint protection validation; WhisperKit `download:false` does not prevent tokenizer network fallback. Two pinned speech download proposals are documented, **not approved**. WW-003 fixture coverage is stage-scoped for bounded research/design, not a waiver of applicable milestone tests. Statuses/owners/criteria and **51 IDs / 196 edges / 3 documentary-completed / 14 partial / 34 pending** remain unchanged. No issues, model bodies, providers, recordings or production code were used; all owned research work ended.

**Historical project-format integration — 2026-10-04: batch closed, APPROVE WITH LIMITS.** [Actual Mac artifacts and Lead's read-only review](docs/research/project-format-recovery.md) retain **6,410/6,410 assertions, zero unexpected failures; 48 boundary groups ×100; 400 owned process exits**. The 100 WAL-copy assertions overlap those exits, not 500 crashes. Complete show/episode human work and durable library truth are compared separately from encoders/indexes; **native app tests 0**, no independent reproduction. One pre-freeze coverage correction separated 91/103 pilots; qualification had no corrections or weaker gates.

**Candidate, not adoption:** single versioned JSON + coherent prior checkpoint + external derived cache; canonically durable library/backend open, device-local access records and rebuildable index separate. Packages require member/revision coherence and retention; SQLite main-only copies missed committed WAL revision8, and **new adapter construction may fail before corrupt-header fallback**. Complete history/primary/library-schema validation, provider/multi-process/stale-job concurrency, real identity/audio/undo and native/reference-device gates remain open. Cloud canonical MVP and accepted autosave/download/shortening/export policies are unchanged.

WW-003/005/006/049 gain **partial evidence only**. Computed before/after **51 IDs / 196 acyclic edges; 3 documentary-completed / 14 partial / 34 pending**, with unchanged owners/criteria/dependencies. WW-007 stays pending: structural library is not native UI; WW-004 remains documentary-completed, WW-009/M1 unapproved. **Lead/Mac documentary handoff due 2026-10-05 is a recommendation, not new execution permission.** The separate parent-provided OFF/Save/ON policy follow-up remains partial (19 asynchronous assertions; dirty-race/dirty-Quit gaps), not reviewed or completed by this batch; historical failures below remain preserved.

**Historical windowed integration — 2026-10-04: UI_BATCH_CLOSED, LOCAL partial evidence only.** The [windowed document report and actual Mac/Design reviews](docs/research/windowed-document-spike.md) retain all **14 IDs: 4 bounded pass / 5 pass-limited / 1 partial / 1 failed-candidate / 1 blocked / 2 not-executed**. One original plus two corrected launches are separate. Focused rename/document Undo/Redo and stock native ON saving were observed, but **~5s at second resolution/configured5s is not ≤2s**. Requested OFF **failed**: native saves continued with empty-type errors1004/Not Saved; unchanged passive bytes did not prove disablement. Explicit Save persisted revision4 and ON was restored. Named Save As/B/cancellation and consented Revert remain unestablished; Close/Quit were clean-only. Parent reports exact corrected no-PID closure and unchanged fixtures, not independent reviewer/Lead checks.

WW-005/008/049 receive **evidence only**, all still PARTIAL; no status changes. **51 IDs / 196 acyclic edges; 3 documentary-completed / 14 partial / 34 pending** remain unchanged. WW-007/009/M1/WW-010–012 remain pending/unapproved. Mac's author-role review and Design's read-only evidence review are not reproduction, human or VoiceOver testing. Stock scheduling/publication/versions were retained in this separate windowed harness; subclass representations/edits/undo/policy remain research, not adopted architecture. Runtime26/16GB, cloud/provider, recovery and full accessibility gates remain open; no production or further GUI execution follows this integration.

**Historical native integration — 2026-10-04: the separate bounded native document batch is closed and reported.** [Actual native evidence and reviews](docs/research/native-document-spike.md) support **28 finite passes / 0 failed assertions**: 24 native runtime cases, one SwiftUI public snapshot runtime case and three compile/control cases, with **nine overlapping blocked limits**, not 37 independent tests. Thirteen genuine NSDocument completions comprise ten Save/three autosave, nine successes/four expected errors. Last-edit-to-independent-coherent-disk observations **0.129026042 / 0.292939875 / 0.546012500s** meet ≤2s only in those three cases; two use custom timers. Stock safe publication was replaced by a research subclass policy, automatic scheduling suppressed and versions disabled. Callback success alone is not persistence; serial stale preflight has TOCTOU, retained-copy reopen is not crash recovery.

Mac's author technical review and Design's actual **approve-with-limits** evidence review support **NSDocument + SwiftUI/versioned JSON values as a candidate, not adopted architecture**. DocumentGroup/packages remain viable; SQLite is untested in this native batch. No UI/accessibility, cloud/provider/two-machine, macOS26 runtime or 16GB evidence was added. WW-005/006/049 gain limited evidence; WW-008 is newly narrowly partial for target26 compilation/plain local bookmarks; WW-007 remains pending. Current backlog: **3 documentary-completed / 14 partial / 34 pending**, unchanged **51 IDs / 196 acyclic edges**. WW-009/M1/WW-010–012 remain pending and unapproved.

**Keep the backlog local.** Brandon's 2026-10-04 direction makes future GitHub issue promotion conditional on completed planning/research, not authorized now. The report's owned permission gates are the next handoff; no experiment rerun, app scaffold or production implementation follows.

**Historical foundation batch, preserved:** original and supplementary protocols retain **169 calibration / 5,728 primary heldout cases**, with all frozen code, inputs, truth, manifests and raw outputs byte-unchanged. Actual Design and Mac **18/18-task** reviews complete **WW-004's documentary specification only**, not native implementation or usability. Its final backlog snapshot was **3 documentary-completed / 13 partial / 35 pending**; no whole research spike or production gate closed.

Historical [planning reviews](docs/planning/research.md#review-evidence-and-dispositions) remain separate from the [five actual foundation review dispositions](docs/research/foundation-spikes.md#review-ledger-and-next-handoff). Alignment approves original finite timing/mapping; Mac accepts only the tested LOCAL storage subset. Pipeline approves original finite edits and separately frozen v2 with nonblocking scope amendments: **336/336 adversarial refusals, 56/56 positive accepts, 32 sequential mode/boundary cases**, zero losses in **1,421 repeated finite frame observations**. Failed controls remain: 400 incoherent publications, 300 stale overwrites, 40 acoustic false accepts and eight original-guard false accepts on four cases already inside v2's 228. No rejection or author lockout occurred.

**Foundation-specific remaining gates, not more execution in that batch:** v2's reload results cover stale/forged caches/assets and valid history-cursor roundtrips; omitted-boundary reload rejection was not isolated and malformed histories/cursors are not validated. The **0.004300041s publication operation** is not edit-to-quiescent latency; the **≤2s checkpoint gate was untested in foundation** (the later three native observations above do not establish product cadence or fault coverage). Sparse timing p95/max **0.1401/0.2006ms** shares 80 maps; estimated inverse maximum is **17.16 source frames**, not subframe accuracy. Half-up rounding and supplied uncut-array regeneration establish no general validator, original-media/DSP reconstruction, speech, native/provider/listening or encoded-DAW support. Host: macOS27.0.1/arm64/128GiB, not macOS26/16GB validation. [Bounded future approval requests](docs/research/foundation-spikes.md#bounded-next-approval-requests--no-execution) retain separate recording, metadata-only native Speech, exact model/runtime, disposable provider/two-machine, reference-device/accessibility and named production permissions.
