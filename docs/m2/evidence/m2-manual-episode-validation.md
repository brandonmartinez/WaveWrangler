# M2 manual alignment on a disposable local episode copy

Refs #20 #188. Run on 2026-10-08 EDT, Apple M5 Max (18 cores, 128 GB),
macOS 27.0.1, at base `3b56f8f` plus the gated manual harness in this PR.
Local and headless only: no network, transcription, speech analysis, original
source writes or GUI. Source labels follow
[the prior local-episode validation](m2-local-episode-validation.md).
The local media location and file names are withheld.

## Operator method and scope

`LocalEpisodeManualTests` requires **both** `WW_LOCAL_EPISODE_DIR` and
`WW_LOCAL_EPISODE_MANUAL=1`; it also requires an empty, guarded
`WW_LOCAL_SCRATCH_DIR` on a local non-cloud volume. CI supplies neither media
nor the opt-in switch. The existing local test remains independently gated.
The test snapshots all original items, decodes approved audio through the
WWDecode gateway and proposes groups from equal sample rate and valid frame
count. The shipped `WWAlignPipeline` also probes and analyses all 12 **full
original sources** with a 600-second analysis excerpt per epoch. Separately,
the harness creates 36-second, channel-preserving, float32 WAVE **copies** from
gateway-decoded frames in scratch storage, rather than rendering 75 minutes
and many gigabytes of output. The copies are the sources supplied to the
pipeline's second plan, analyse, accept, activate and aligned-asset render.
Unsupported audio is never copied or registered.

The operator selected known source-frame trim boundaries near minute 28:
G1 at 1,700 s, G2 at 1,702 s, G3 at 1,704 s, and G4 at 1,706 s.
Those selections preserve a common 30-second-plus interval in the copies.
Using the episode's **equal-origin assumption** (not a verified clock
reference), the numeric decisions entered through the UI's pipeline API
were 0 ppm and respectively +2,000, +4,000 and +6,000 ms for G2–G4:
`offset = (target trim start frame / target sample rate − reference trim
start frame / reference sample rate) × 1,000 ms`. This is a manual placement
of short excerpts, **not** an acoustic estimator result or a claim that the
original recorders' clock drift or offset is zero. No `clockApproved` state
was constructed. The S-number-to-group guard refuses a different layout
rather than silently assigning a wrong trim.

The full-source pipeline probed all 12 supported originals and analysed G2,
G3 and G4 against G1. All three epochs abstained: G2 `discontinuous` (2/16
eligible windows), G3 `weak` (0/16), G4 `silent` (0/16). The second pipeline
probed the 12 copies and also abstained in all three epochs as `silent`
(0/16 each). These are observations for this configuration, not clock
accuracy estimates or a replacement for #188's estimator diagnosis.
Numeric manual decisions were accepted at revision 1 and activated by the
coordinator; state resolution returned U1 Reference and three U4 Manual
(`numericEntry`) epochs. This verifies a usable manual path *despite*
abstention. It does not establish that this placement synchronizes the
original episode. An independent held-out cross-recorder acoustic residual
could not be established from these silent excerpts, so none is reported as
an accuracy measure.

## Measured run

One isolated release/testable package run, SwiftPM `--jobs 4 --no-parallel`,
under `timeout --kill-after=30 1800`. The extra `-DDEBUG` compiles unrelated
gateway-hook test targets, but the hooks default to nil. Scratch was a fresh
temporary directory outside the repository and synced folders; the run used
`--filter LocalEpisodeManualTests`. Counts below are for the **36-second
copies**, not full-length assets.

| Check | Measured outcome |
| --- | --- |
| Sources | 16 items listed, 13 audio; 12 supported and copied, 1 typed unsupported-container refusal, 3 non-audio unopened |
| Full-original plan / analyses | 4 groups, 12 eligible sources and probed facts; 3/3 target epochs abstained (G2 discontinuous 2/16 eligible, G3 weak 0/16, G4 silent 0/16) |
| Copy plan / analyses | 4 groups, 12 eligible and probed copies; 3/3 target epochs abstained (silent, 0/16 each) |
| Decision / activation | Three U4 numeric manual epochs, one U1 reference, revision 1; **one accepted map digest** across all assets |
| G1 | 14/14 channels; 1,728,000 frames/channel (36 s at 48 kHz); 84 segment assets |
| G2 | 3/3 channels; 1,728,000 frames/channel (36 s at 48 kHz); 21 segment assets |
| G3 | 1/1 channel; 1,728,000 frames/channel (36 s at 48 kHz); 7 segment assets |
| G4 | 1/1 channel; 1,728,000 frames/channel (36 s at 48 kHz); 6 segment assets |
| Shape / version | Every asset header's output rate, accepted revision, channel and frame count checked against the group's output hull; 19/19 channels, 118 assets |
| Cancellation | An active aligned-asset render was cancelled: incomplete report in **0.904 s** (<5 s); idle shutdown took <0.001 s |
| Time / memory | Complete render 57.25 s; entire validation 88.3 s; process peak resident 16,597 MB, including resident full-episode analysis buffers |
| Originals | 16/16 items unchanged on size, mtime, ctime and inode; 13/13 audio SHA-256 unchanged (15.00 GB hashed each pass) |

The harness removed the full-source analysis cache, temporary input copies and aligned derived assets and
verified the scratch directory empty. The operator then removed that
directory and its separate local run log; absence was verified. No derived
assets, media names, screenshots or transcript content are committed.
After the run, process inspection showed no orphan from this validation.

## Phase-isolated memory follow-up (2026-10-08)

The original combined run's 16,597 MB process peak **is not an attributable
pipeline peak**. An initial attempt to sample after the read-only 15.00 GB
checksum pass found an already-high idle baseline (14,383 MiB RSS,
14,351 MiB footprint). The checksum reader used 8 MiB streaming blocks, but
its Foundation read allocations accumulated without a per-block autorelease
pool. The checksum loop now drains each block's autorelease pool. More
importantly, checksums run in **separate processes** before and after both
measured processes: neither measured process hashes full sources or retains
the old manual harness's 12 full-episode analysis buffers. The matching
aggregate checksum covers all 13 audio items, while size, mtime, ctime and
inode cover all 16 items. The temporary inode-to-S-label map preserves the
prior harness's SHA-based tie ordering without hashing inside a measured
process. It is not committed.

Each measured phase used its own opt-in `LocalEpisodeMemoryTests` SwiftPM
release/testable process (`--jobs 4 --no-parallel`, one test filtered,
`timeout --kill-after=30 1800`). The production `AlignmentPipeline` used
concurrency 1. The first phase analysed all 12 **original, full-length**
supported sources (600-second target analysis excerpts), with no separate
full-length decode buffers; G2/G3/G4 abstained discontinuous 2/16, weak 0/16
and silent 0/16, respectively. The second phase decoded only bounded
36-second, channel-preserving buffers to create temporary local WAVE copies,
then planned, analysed, accepted and activated the same operator's numeric
decisions on those copies. It sampled **only the aligned-asset render**, after
copy preparation and acceptance; the complete render produced 118 assets,
19 channels, 36 s/channel. It did not share a process with the original
analysis, and never held full-episode analysis buffers. Sampling used
`TASK_VM_INFO` resident size and physical footprint every 2 ms on a dedicated
thread, including a final sample; peaks are process-wide sampled values, not
per-operation allocations or a guarantee against sub-2-ms spikes.

| Isolated phase | Idle RSS / footprint | Peak RSS / footprint | Measured operation | Pre-run load average |
| --- | --- | --- | --- | --- |
| Full-original analysis | 45 / 9 MiB | **369 / 330 MiB** | 7.36 s | 12.72 |
| Bounded aligned-copy render only | 111 / 71 MiB | **141 / 102 MiB** | 66.75 s | 10.23 |

Both measured peaks were below about 2 GiB on this 128 GB host; these
figures do not establish a 16 GB host bound or a full-episode render bound.
No rendering of original full-length media, transcription, speech analysis,
network transfer, GUI operation or screenshot was performed. The original
folder remained read-only; phase scratch, derived assets, temporary copy
inputs, checksum-label map and local run logs were removed and their absence
verified. No validation processes remained after the runs. The opt-in
switches `WW_LOCAL_EPISODE_DIR`, `WW_LOCAL_EPISODE_MEMORY_PHASE` (`snapshot`,
`original`, `render`), `WW_LOCAL_EPISODE_LABEL_MAP` and (for measured
phases) `WW_LOCAL_SCRATCH_DIR` are not provided by CI; CI exercises only
synthetic consent guards.

## GUI smoke limitation

No real-media Mac mini GUI smoke was attempted: the app has no DEBUG-only
launch path to import this approved local episode into a disposable show,
and the existing fixture launcher is synthetic. The Mac mini's required
GUI lease was occupied by another M2 exit suite during this run. Adding a
new app-level real-media launch/import surface for one smoke would expand
this PR beyond the gated, headless validation and risk private names in UI
artifacts. **U-state resolution was checked through the same pipeline state
API used by Alignment, but visible labels and remedies on real media were
not verified here.** No screenshots were taken.
