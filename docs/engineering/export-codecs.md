# Export codecs and delivery jobs

The app renders the frozen production program once, then `WWExport` converts,
encodes, verifies and publishes explicit deliveries. Encoders do not open source
recordings, mix, choose episode bounds, grant access or publish final files.

## Codec contract

`ExportEncoder` accepts already-converted interleaved Float32 in finite blocks
of 1-16,384 frames. Float WAV preserves finite overunity; integer/lossy input
must fit [-1,1]. Invalid format/headroom refuses rather than silently converting
or clipping.

| Codec | Rates (kHz) | Channels | Options |
| --- | --- | --- | --- |
| WAV/RIFF | 44.1, 48, 88.2, 96 | Mono/stereo | Signed 16/24-bit integer or 32-bit float |
| MPEG-1 Layer III MP3 | 44.1, 48 | Mono/stereo | CBR 64/80/96/112/128/160/192/224/256/320 kbps; LAME VBR quality 0-9 |
| AAC-LC M4A | 44.1, 48 | Mono/stereo | System CBR 64/96/128/160/192/256 kbps |

WAV refuses RIFF output beyond 4 GiB; RF64 is not implemented. MP3/AAC reject
88.2/96 kHz and AAC VBR is not exposed. MP3 CBR below 64 kbps cannot reliably
hold the required Xing/LAME gapless/seek tag at supported geometry.

Create the encoder actor in an existing caller-owned private staging directory;
it creates a unique mode-0700 child. Append consumes bounded native buffers;
failure makes the encoder unusable. `finish()` flushes headers/converter/
metadata, then reopens and decodes the **entire** owned output in 4,096-frame
buffers. Return `VerifiedExport` only after format, finite samples, nonempty
output and frame/duration verification.

WAV is frame-exact. Decoder-visible priming/padding tolerances are at most
2,304 MP3 or 3,072 AAC frames, explicitly reported as `decodedFrameDelta`.
These do not adjust production timing or excuse truncation.
MP3 verifies every MPEG packet boundary, Xing bytes/packets and the LAME
input-frame equation; an empty native EOF is accepted only with that audit
and sufficient decoded PCM. AAC preserves packet-table/edit timing.

The staging URL is not a permanent validity token. Reverify after any copy or
transformation; the coordinator checks currency and commits deliveries separately.
Always invoke throwing, idempotent `cancel()` after copying finished output or
on failure. Dropping an actor closes native resources, not disk artifacts.

Cleanup retains descriptors and identity/change witnesses and removes only
unchanged owned files, then an empty owned directory. Unexpected entries,
replacements, in-place changes and unconfirmed partial remux files remain with
explicit cleanup errors, not recursive deletion. Cancellation propagates to an
active AAC metadata framework session/task and joins it before cleanup or a
terminal result. Native encoding checks cancellation at bounded block boundaries.

## Frozen production jobs

`ShowDocument.exportJobs` is one `EpisodeExportService` per show shared by all
windows; `exportInterface` owns one presentation. Before freezing:

1. Dismiss native editors and capture authoritative `fullStateForDocument`
   for every loaded instance, including units without observation baselines.
2. Stop only that show's registered transports and retire live effects.
   Gate new playback while exporting.
3. Freeze canonical processing, metadata and source/timing evidence, then use
   independent offline effect instances through
   `AlignmentRuntime.renderProductionOffline`.

   The independent processor requests offline Audio Unit mode and up to 4,096-frame
   effect blocks, honoring the smallest allocated effect capacity. It overlaps one
   bounded next source window with processing/writing, never parallelizes a stateful
   effect chain, and cancels/joins preparation on every failed exit. Playback remains
   on its existing 512-frame blocks. See [audio processing](audio-processing.md)
   for timing checks and retained-buffer bounds.

Render only resolved Episode Start through Episode End on the signed 48 kHz
grid, including persistent routing/gain/effects/clips/envelopes/cuts/mutes.
Do not inherit transient listening Solo/Mute. No effect tail is appended;
extend Episode End explicitly to retain decay.
Missing effects, stale/unauthorized/unavailable sources or changed inputs fail.
Check the frozen document generation, cancellation and device-access mutation
revision on every render/conversion/decode/transfer block. Store revisions are
invalidation witnesses, not grants: memory stores change an opaque token on
mutation; file stores inspect permission-file identity, size and change times
without loading JSON. An equal-byte revoke/restore still invalidates the job.
When the shared store changes, compare only the frozen recipe's access snapshots
and recheck the revision across that read; unchanged relevant snapshots permit
an unrelated show's mutation without reloading records on subsequent blocks.
Full source/admission validation runs at phase boundaries and immediately before
each publication commit. Actual source reads retain their witnessed gateway
checks; completed production windows still revalidate their sources. Never cache
permission data or grant reads from a revision or a rendered intermediate.

`ExportJob` accepts an explicitly selected destination, protected locations,
range and 1-16 distinct deliveries. Its renderer runs once into a finite,
contiguous stereo Float32 disk intermediate (mode 0600) in a private mode-0700
application temporary directory, alongside each private encoder directory.
The destination receives no provisional audio during rendering or encoding.
PCM remains provisional until rendering and final
currency succeed. Every write/read/pass/cleanup revalidates the retained
descriptor's identity, size/change timestamps, regular-file type and single
link; do not adopt external edits after partial failure.

Deliveries process sequentially. Mono is arithmetic `(left + right) / 2`.
Rate conversion follows the 48 kHz mix, drains EOF, and emits the nearest whole
frame count for that rate/duration. Optional TPDF adds triangular one-LSB dither
only before 16/24-bit integer quantization; default is none. Dither is invalid
for float/lossy formats.

Preflight checks extensions, normalized case-insensitive collisions, protected
paths, aliases/symlinks/hardlinks, existing entries, RIFF limit and conservative
disk space for local PCM, all outputs, remux overhead and destination copies.
Check both volumes separately, or their combined budget on a shared volume.
No overwrite is allowed.
Full decode verification of **all** deliveries precedes publication of any.
Copy each verified local delivery into a private destination-volume directory
in bounded 256 KiB blocks, synchronize it, then compare every byte with the
unchanged verified local output. This works across volumes without assuming an
atomic move. Recheck retained descriptors, change witnesses and currency
throughout the transfer. Only destination copies may accept a ctime-only update:
the retained and named files must still have the same identity, size, modification
time, regular-file type and single link, and every copied byte must match the
unchanged verified local output across a stable verification window. Metadata
updates during verification restart that comparison, with at most three attempts;
continuously changing metadata or differing bytes fail and preserve the copy.
PCM, local encoders and cleanup retain strict change witnesses. Revalidate sources
after any comparison and immediately before the synchronous publication commit;
metadata changes across that admission boundary also have a three-attempt limit.
Each destination-local `renameatx_np(RENAME_EXCL)` is a commit point, not an
unsafe replace/rollback. Keep actual published receipts if a later commit fails.
On destination/publication failure, retain still-owned, fully verified local
encoder outputs and report their directory. Remove the PCM intermediate; do not
present retained files as published receipts or automatically retry them.
Changed local artifacts instead retain the existing explicit cleanup refusal.

Folder scope covers cleanup. Staging/destination identities are checked around
publication; replaced artifacts remain for inspection with errors.
`succeeded` requires both job and cleanup success. Always inspect `published`
even for cancellation/failure; partial delivery is not full success.

## Public metadata and omission consent

Resolve canonical show defaults plus per-field episode overrides. `nil`
inherits, empty text omits, false is explicit, and artwork `.none` suppresses
inheritance. Private Notes, source paths and bookmarks never become metadata.
Export-only overrides do not edit the show.

`ExportMetadata` supports title, artist, album, public description, copyright,
genre, ISO date, positive episode number and JPEG/PNG artwork. Text is <=64 KiB
per field without NUL. Export artwork is <=8 MiB and 4,096 pixels per side,
stricter than portable artwork's 10 MiB.

MP3 writes ID3v2.4 UTF-8 title/artist/album/copyright/genre/date/episode,
COMM/TXXX description and APIC cover. M4A uses equivalent iTunes atoms including
`tves`/`covr`; passthrough metadata remux adds a disk file, not whole-episode PCM.
WAV LIST/INFO is ASCII-only, without artwork or episode number.

Preview exact omissions using `ExportMetadataAdapter.preview` before setting
`confirmedOmissions`. WAV Unicode/artwork/episode number and unsupported
publisher/language/website/explicit/season/type mappings require explicit
omission consent, not silent stripping or a disabled codec. Oversized portable
artwork needs export-only replacement or omission, never implicit recompression.

Any draft format/normalization/metadata change revokes consent; document
generation changes revoke it too. The backend re-resolves the frozen publication
and requires exact current omissions. Saved export preferences never remember
metadata overrides or omission approval.

## Loudness and decoded reports

Normalization defaults Off. Podcast suggests -16 LUFS stereo/-19 mono and
-1 dBTP; custom finite targets span -36 to -9 LUFS with ceilings -12 to
-0.1 dBTP. This is delivery-only, not source input normalization.

The BS.1770/EBU-style meter uses rate-specific K weighting, 400 ms windows at
100 ms hops, -70 LUFS absolute and -10 LU relative gates. A 0.01 LU energy/
count histogram bounds state independently of duration (about 1.4 MiB).
Shorter-than-400-ms or ungated programs have no integrated loudness.
Silence is not a successful target result or a reason to amplify noise.

True peak uses 4x polyphase reconstruction with 64 input taps/phase, including
raw samples and zero-extension/flush at edges. It is not sample peak or a
certified broadcast-meter claim. Smooth calibration tolerance is 0.15 dB;
abrupt-edge/burst tolerance is 0.7 dB. Reserve 0.7 dB below requested ceiling
plus 0.05 dB on the first encode.

Measure after requested downmix/rate conversion, before dither/quantization.
Apply one constant gain limited by target, +24 dB boost cap and peak headroom.
Unmeasurable programs are never boosted. There is no limiter, extra tail or
effect rerender. Off performs no gain adjustment; integer/lossy overload still
fails actionably and float WAV retains finite overunity.

Measure the fully decoded result. Peak overshoot triggers attenuation by the
excess plus 0.1 dB and a fresh encode from the same intermediate, at most three
corrective re-encodes. Ownership/currency/cancellation checks remain on every
pass and attempt disposal. Failure to meet the bound fails before publication.

Reports include actual measurement, requested target/ceiling, applied gain,
corrective attenuation/passes and honest status: `off`, `achieved` (within
0.2 LU), `peakLimited`, `boostLimited`, `unmeasurable` or `targetMissed`.
Codec level changes are not automatically blamed on peak headroom.
Keep encoder-input and decoded counts; lossy padding is not exact duration.

## Native interface and lifecycle

File > Export (Command-4), toolbar and legacy destination routing use
`ShowWindowState.requestExport()`. Serialized export/menu keys remain stable,
but export is one sheet, not a second View destination. A stale saved export
destination falls back to Alignment. Another show's job remains independent.

The sheet shows signed Start/End/duration, typed codec controls, common base
name, explicit folder picker, normalization and export-only metadata.
No selection/subtimeline, realtime, appended-tail, overwrite or extra destination
mode is implied. Running jobs block dismissal and document close/quit until
cancel/cleanup completes. Recheck running state **after awaited native capture**
as well as before it.

Save device-local per-ShowID options and scoped destination bookmark only after
full success. Stale/malformed preferences require visible repair/fresh selection.
Result Reveal/Open actions apply only to real committed receipts.
Help > Software Licenses loads exact first-party MIT, upstream LAME and Whisper
resources; missing notices are visible failures, not an empty success.

## Licensing and release gate

LAME 3.100 is GNU Library General Public License version 2 or later, not
relicensed under the app's MIT license. Preserve its unmodified `COPYING`,
`LICENSE`, source notices and `lame.c` grant. The full original archive is
`Packages/WaveWranglerKit/ThirdParty/lame-3.100.tar.gz`:

```text
https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
SHA-256 ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
```

Only the explicit portable encoder C list compiles, with `-O2`; no CLI,
`mpglib`, assembler or external runtime executable is linked. The complete
archive retains upstream optional components as source materials.
`WWLameNative/config.h` is generated on arm64 macOS using:

```sh
./configure --disable-decoder --disable-frontend --disable-shared --disable-nasm
```

Use the configure script from the release in a separate extraction directory;
do not alter upstream bytes just to regenerate configuration.
`python3 scripts/check-lame-source.py` audits pristine bundled source.
An intentional LGPL-compatible ABI-preserving library modification fails that
pristine audit; it is not permission to change the expected upstream hash.
Rebuild/relink all codec consumers from source in fresh output:

```sh
swift test --package-path Packages/WaveWranglerKit \
  --scratch-path .build/lame-relink --jobs 2 --filter WWExportTests
WW_JOBS=2 WW_DERIVED_DATA="$PWD/.build/LameRelinkDerivedData" scripts/build.sh Debug
```

This is a full source rebuild, not a dylib dropped into a signed Store app.
The exact binary release needs corresponding application/wrapper/library source,
build materials and usable relink/local-signing instructions, plus applicable
modification/reverse-engineering rights. Attribution or an upstream homepage
alone is insufficient under
[section 6](https://www.gnu.org/licenses/old-licenses/lgpl-2.0.html).

**Release clearance remains open.** Validate exact source/relink packaging,
linkage, signing, sandbox, library validation, distribution restrictions and
then-current App Store terms for the actual release, with open-source licensing
counsel. MIT/commercial sale and
[Apple's EULA open-source exception](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)
are not blanket clearance. Test signing, synthetic codec results and VM UI
passes do not resolve this gate.

## Validation scope

Generated-PCM `WWExportTests` cover bounded encoding, structural/duration
verification, metadata, loudness/headroom, local staging, verified transfer,
transfer cancellation/tampering, boundary-only full validation, ownership,
collisions, retained recovery files and partial receipts. Optional independent comparison uses only already
installed FFmpeg through `WW_EXPORT_REFERENCE_FFMPEG`; it is not a production
dependency or permission to install one. App adapter, hosted native-state and
real UI coverage are separate layers in [testing](testing.md). A focused run
or a suite with excluded files must never be reported as a full-suite pass.
