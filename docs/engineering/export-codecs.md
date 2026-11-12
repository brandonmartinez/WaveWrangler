# Export codecs and production jobs

`WWExport` is independent of the document and mixer. Its `ExportEncoder` accepts already converted,
interleaved Float32 PCM in bounded blocks (1...16384 frames, finite). Float WAV
preserves finite over-range values; integer/lossy codecs require [-1, 1].
It does not open source recordings, mix, resample, downmix, normalize,
choose an episode range, or publish a delivery file.

## Public contract

`ExportSettings(codec:sampleRate:channels:)` validates:

| Codec | Rate (kHz) | Channels | Options |
| --- | --- | --- | --- |
| WAV/RIFF | 44.1, 48, 88.2, 96 | 1, 2 | Signed 16/24-bit integer or 32-bit float |
| MP3, MPEG-1 Layer III | 44.1, 48 | 1, 2 | CBR 64/80/96/112/128/160/192/224/256/320 kbps; LAME VBR quality 0...9 |
| M4A, AAC-LC | 44.1, 48 | 1, 2 | System constant-bitrate encoder, 64/96/128/160/192/256 kbps |

AAC VBR is deliberately not exposed. The system AAC encoder rejected all tested
88.2/96 kHz combinations (mono -66567, stereo -50); those rates are rejected up
front. WAV rejects output above RIFF's 4 GiB limit;
RF64 is not implemented. MP3 rejects 88.2/96 kHz rather than silently converting.
The job layer below makes conversion and headroom policy explicit;
normalization Off preserves levels through floating-point WAV.
MP3 CBR below 64 kbps is rejected because its MPEG-1 frame cannot consistently
hold the Xing/LAME gapless/seek tag at these rates and channel counts.

1. Create an `ExportEncoder(stagingDirectory:settings:metadata:)` actor in an
   existing caller-owned private staging directory. It creates a unique mode-0700
   child directory, never an existing destination file.
2. `append(interleaved:)` synchronously consumes each block on the actor. It retains
   only bounded native buffers. An append failure makes the encoder unusable.
3. `finish()` flushes converter state and headers, writes metadata, and reopens and
   decodes the complete result with a 4096-frame buffer. Empty, wrong-format,
   nonfinite or duration-mismatched outputs fail. It returns `VerifiedExport`
   (`stagingURL`, settings, input/decoded frame counts, delta, byte count).
4. The coordinator must verify job currency/authorization and perform its own
   transactional delivery publication. The URL is not a permanent validity token:
   keep staging private and reverify after any copy/transformation. Do not expose
   partial files or overwrite a delivery destination from inside the codec.
5. Always call throwing, idempotent `cancel()` to dispose the owned child directory,
   after copying a finished result or on failure/cancellation. Cleanup errors are
   surfaced. Dropping the actor closes native resources but is not disk cleanup.

Cancellation is checked at append/finalize/decode boundaries. Canceling during an
M4A remux cancels that session; no finalized result can then be returned. No actor
method suspends during native encoding, so queued cancellation takes effect at the
next bounded block. No desktop app or user recordings are needed for qualification.

Encoder cleanup retains file descriptors and identity/change witnesses for its
generated files, including partial native output and successfully remuxed M4A.
It unlinks only unchanged owned files and removes the directory only when empty.
Unexpected entries, replacements and in-place external edits are preserved with
throwing cleanup errors. Cancellation joins an active metadata remux before
cleanup. A failed framework remux cannot establish ownership of a remaining
partial `tagged.m4a`; that unconfirmed entry is preserved and reported, not adopted
or recursively deleted.

MP3 finalization overwrites the reserved Xing/LAME frame with frame/byte counts and
encoder delay/padding. Verification audits every MPEG packet boundary, the exact
Xing byte/packet count, and the LAME input-frame equation. Core Audio sometimes
overestimates CBR MP3 length (observed at 96 kbps/44.1 kHz); an empty native EOF
is accepted only after that structural audit and enough decoded PCM. Truncation
or an incorrect gapless frame count is never excused by the duration tolerance.
AAC preserves the system encoder's packet table/edit timing.
Decoder-visible priming/padding varies: verification permits at most 2304 MP3 or
3072 AAC frames difference; WAV must be frame-exact. These are codec-container
tolerances, not adjustments to production timing. `decodedFrameDelta` makes the
observed difference explicit.

## Public metadata

`ExportMetadata` carries optional title, artist, album, public description,
copyright, genre, ISO 8601 date, positive episode number, and `ExportArtwork`.
There are no private-note or source-path fields. Text is limited to 64 KiB per
field, rejects NUL, and artwork is decoded/validated JPEG or PNG (8 MiB, 4096 pixels
per side maximum).

MP3 uses ID3v2.4 UTF-8: TIT2/TPE1/TALB/TCOP/TCON/TDRC/TVES, COMM plus
TXXX:DESCRIPTION, and APIC front-cover artwork. M4A uses the equivalent iTunes
metadata atoms including description, `tves` and `covr`; a system passthrough
remux adds them without re-encoding audio. This uses a second disk file, not a
whole-episode PCM allocation.

WAV uses RIFF LIST/INFO INAM/IART/IPRD/ICMT/ICOP/IGNR/ICRD, restricted to ASCII
for interoperability. Artwork and episode numbers are explicitly rejected for
WAV, not silently discarded. A later UI must communicate that limitation.

## Document-owned production jobs

The app links `WWExport`. One observable `ShowDocument.exportJobs`
(`EpisodeExportService`, MainActor) owns the job for every window on that show.
Call:

```swift
let result = try await document.exportJobs.run(
    episode: episodeID, runtime: runtime,
    userSelectedDirectory: selectedFolder, deliveries: selections)
```

`selections` contains `EpisodeExportDelivery(filename:settings:)` values, with
optional publication overrides, title/album overrides, integer-WAV dither, loudness normalization and
confirmed omissions. Before submitting, call
`ExportMetadataAdapter.preview(resolved, delivery:)` using
`try model.resolvedPublication(for: episodeID)`. Present its omissions and copy
only explicitly accepted omissions into `confirmedOmissions`. The backend
refuses unconfirmed omissions. It resolves defaults again from the frozen
snapshot; a concurrent metadata change cannot silently reuse obsolete consent.
An export-only empty string or `.none` artwork suppresses inheritance without
changing the show. Private Notes are never copied.

WAV can be selected even when the show has Unicode text, artwork or an episode
number: unsupported fields become explicit omissions, not silently stripped tags
or an impossible format choice. Publisher, language, website, explicit-content
flag, season and episode type currently have no qualified codec mappings and
also require omission confirmation. Original artwork between 8 and 10 MiB
requires smaller export-only artwork or explicit omission; no automatic
recompression or truncation occurs.

The service exposes `isRunning`, typed `state`, `progress`, `lastResult` and async
`cancel()`. Setup errors throw and set failed/canceled state. Once the package job
starts, its result reports typed failure/cancellation, committed files and
cleanup errors; `succeeded` requires both a successful job and successful cleanup.
Always inspect `published`, even on failure: a later publication can fail after
an earlier file was committed.

Before freezing, the mixer barrier dismisses native editors, captures
authoritative `fullStateForDocument` for all loaded instances (including those
without an editor-observation baseline), stops only this document's registered
transports and retires its live effects. New playback is gated while exporting.
Export uses `AlignmentRuntime.renderProductionOffline` and independent offline
effect instances. It includes persistent production edits, routing, gains,
inserts, cuts, fades and clips, never transient Solo/Mute/listening controls.
Missing effects and unavailable, unauthorized or stale sources fail explicitly.
Only resolved Episode Start through Episode End is rendered on the signed
48 kHz production grid. No effect tail is appended; extend Episode End to keep
decay. Document equality, media verification and source admission are checked
during rendering/conversion and before every publication.

### Package job contract and conversion

For non-app integration, create one `ExportJob` actor per document and call
`run(_:isCurrent:render:progress:)`. An `ExportJobRequest` requires an explicitly
selected destination folder, all protected locations, the production frame
range and 1...16 distinct `ExportDelivery` values. The renderer callback is
invoked once and receives a bounded sink `(firstFrame, stereo)`. Its output is
provisional until the renderer returns and currency succeeds: use the existing
production renderer rather than a second mixer or arbitrary source reader.

The sink writes finite, contiguous stereo Float32 to a private mode-0600 disk
intermediate within a unique mode-0700 directory on the destination volume.
Memory stays bounded by the production window and converter buffers, not episode
duration. Deliveries are processed sequentially from that intermediate. Mono is
the arithmetic average `(left + right) / 2`, not a selected channel or an
unattenuated sum. Rate conversion follows the 48 kHz mix, drains EOF, and emits
the nearest whole number of frames for the requested rate and episode duration.
`ExportDither.none` is default; `.tpdf` adds triangular one-LSB dither before
16/24-bit integer quantization. It is rejected for floating/lossy formats.

Normalization defaults to Off. Float32 WAV preserves finite over-unity values. Conversion
overs and integer/lossy overload fail with an actionable headroom error; there
is no automatic clipping, gain adjustment or substitute silence. Full decoded
verification precedes publication of *any* delivery. Published receipts report
both encoder-input and decoded frame counts; lossy padding is not represented as
an exact production duration.

Preflight checks extensions, normalized/case-insensitive filename collisions,
protected paths, directory aliases/symlinks, existing entries (including hardlinks),
RIFF limits and a conservative disk budget for intermediate plus all outputs and
remux overhead. Existing files are always refused. Folder security scope spans
the job and cleanup. Destination/staging identities are rechecked; per-file
`renameatx_np(RENAME_EXCL)` is the commit point, with no overwrite race or unsafe
rollback. Cancellation/failure cleans owned artifacts and reports cleanup errors;
replaced staging is preserved, not followed. No original media is opened by this
layer.

### Optional export loudness and delivered-file reports

`ExportDelivery(..., normalization:)` and the app's `EpisodeExportDelivery.normalization`
accept `ExportNormalization.off` (default), `.podcast`, or
`.custom(targetLUFS:ceilingDBTP:)`. Podcast suggests -16 LUFS stereo or -19 LUFS
mono with a -1 dBTP ceiling. Custom targets must be finite and within -36...-9
LUFS; ceilings within -12...-0.1 dBTP. This is export-only, not source input-gain
normalization, and never modifies a show or original recording.

The meter uses the BS.1770 K-weighting shelf/high-pass coefficients recalculated
for each requested output rate. Stereo channel energies have unity weights
(mono has one channel); there is no surround/LFE path. Integrated loudness uses
400 ms blocks with 100 ms hops, a -70 LUFS absolute gate and a second gate 10 LU
below the absolute-gated mean. An energy/count histogram at 0.01 LU resolution
bounds duration-independent gate state (about 1.4 MiB), with a 400 ms energy ring
and constant filter state. This is BS.1770/EBU-style engineering qualification,
not a claim of formal broadcast-meter certification. Programs shorter than
400 ms or without an absolute-gated block return `integratedLUFS == nil`.
Silence is not reported as achieving a target.

True peak is **not** sample peak: a four-times polyphase, 64-input-tap-per-phase
Blackman-windowed sinc reconstructs each channel. Raw samples are included,
with zero-extension and filter flushing at both edges. Meter delay/flush never
changes delivered samples, Start/End or duration. Finite reconstruction filters
disagree most at hard boundaries: normalization reserves **0.7 dB below the
requested ceiling**, plus 0.05 dB on the first encode. Treat reported peaks as
estimates, not 0.1 dB-certified measurements; calibrated smooth signals agree
with the reference within 0.15 dB, abrupt/burst fixtures within 0.7 dB.
Digital silence has `truePeakDBTP == nil`; near-silence can have a finite peak
but no measurable integrated loudness.

For enabled normalization, a bounded conversion/measurement pass reads the
existing private intermediate after the requested downmix and rate conversion,
before dither or quantization. One constant gain is the minimum of the requested
loudness gain, a **+24 dB boost bound**, and peak-constrained headroom including
the reserve. Unmeasurable programs are never boosted (but may be attenuated to
respect a ceiling). There is no limiter, lookahead, extra tail or effect rerender.
Encoding separately reapplies conversion and then gain/dither/quantization.
Off skips normalization measurement and adjustment; integer/lossy overload
still fails actionably, and Float32 WAV still preserves finite over-range PCM.

Every `ExportEncoder.finish()` measures the fully decoded, owned output inside
the existing verifier; `VerifiedExport.loudness` exposes its
`ExportLoudnessMeasurement`. No new arbitrary-URL decoding API or source-reader
exception is added. Normalized jobs check the **decoded** peak, including codec
priming/padding, against the reserved ceiling. An overshoot triggers attenuation
by the excess plus 0.1 dB and a fresh encode from the intermediate. At most three
corrective re-encodes are allowed; failure to meet the bound fails before any
publication. Each replaced attempt is ownership-validated and disposed with
throwing cleanup before creating another. No extra disk intermediate is added;
the existing conservative PCM-sized output/remux budget still covers the peak
simultaneous artifacts. Effects render exactly once across all deliveries and
passes. Admission/currency/cancellation checks run at every converted and decoded
block and before attempt disposal/publication. Progress distinguishes
`.measuring(delivery:)`, `.correcting(delivery:attempt:)` and verification.

`PublishedExport.loudness` is an `ExportLoudnessReport`: actual final
`measurement`, optional `requestedTargetLUFS`/`ceilingDBTP`, total
`appliedGainDB`, positive `correctiveAttenuationDB`, `correctionPasses` and
`targetStatus`. Status is `.off`, `.achieved` (final loudness within 0.2 LU),
`.peakLimited`, `.boostLimited`, `.unmeasurable` or `.targetMissed`.
The last status explicitly handles codec-dependent level changes without falsely
blaming the peak ceiling or claiming success. For example LAME's decoded
1 kHz output can be about 0.45 LU lower than the input even with ample peak
headroom. Reports describe decoded files, not a fictional exact program duration;
the existing input/decoded frame counts and lossy tolerances remain authoritative.

Qualification uses generated PCM only. Tests cover calibrated 1 kHz mono/stereo
at all four WAV rates, absolute/relative gates, silence/near-silence, cancellation
downmix, intersample peaks, custom validation, boost/peak bounds, dither,
Off/Float32 over-range behavior, sample-for-sample fixed-gain timing, one render,
actual MP3/AAC overshoots, correction cancellation/staleness and staging cleanup.
Independent optional reference tests use an **already installed** FFmpeg, never
a production executable or runtime dependency:

```sh
source "$HOME/.shell/exports-core.sh"
umask 022
WW_EXPORT_REFERENCE_FFMPEG="$(command -v ffmpeg)" \
  WW_JOBS=2 WW_TEST_WORKERS=2 SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=2 \
  swift test --package-path Packages/WaveWranglerKit \
  --scratch-path .build/swiftpm --jobs 2 --filter WWExportTests
```

FFmpeg 9.0.2's `ebur128=peak=true` independently qualifies smooth 1 kHz tones,
absolute/relative gated programs, quarter-rate intersample tones, hard edges and
bursts; the tests enforce 0.1 LU integrated agreement and the peak tolerances above.
They also independently decode final MP3/AAC deliveries and require their
reference peaks not to exceed the selected ceiling. No optional tooling is
installed. Export sheet/menu/toolbar, license UI and dedicated VM qualification
remain separate phases.

## LAME provenance and rebuilding/relinking

LAME 3.100, <https://lame.sourceforge.io/>, is distributed under the GNU Library
General Public License version 2 or later; see the unmodified `COPYING` and
`LICENSE` in `Sources/WWLameNative/upstream`. Copyright notices remain in every
source file. It comes without warranty. This is not relicensed under the
application's MIT license.

The complete original release is in `Packages/WaveWranglerKit/ThirdParty/lame-3.100.tar.gz`:

```text
https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
SHA-256 ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
```

Only the explicit encoder C source list in `Package.swift` is compiled. No
`mpglib` decoder, CLI frontend, assembler or external runtime executable is
compiled/required. The complete upstream archive contains those upstream optional
components solely as corresponding source material, not linked code.

`WWLameNative/config.h` is generated, not a modified upstream header, using the
release's configure script on arm64 macOS:

```sh
tar xzf Packages/WaveWranglerKit/ThirdParty/lame-3.100.tar.gz -C /tmp
cd /tmp/lame-3.100
./configure --disable-decoder --disable-frontend --disable-shared --disable-nasm
```

The package uses the portable C encoder with `-O2` in both configurations and
the checked-in generated configuration. The full archive supplies configure,
Makefiles and all original build materials for independent library builds.

The practical development replacement path is a **full rebuild/relink**, not
replacing a dylib in a signed application. No Homebrew encoder is needed:

```sh
# From a source checkout, first check the pristine bundled library.
python3 scripts/check-lame-source.py
# Replace or modify encoder files under Sources/WWLameNative/upstream/libmp3lame
# (relative to Packages/WaveWranglerKit) with your LGPL-compatible replacement.
# Keep the public LAME ABI. Intentional modifications will fail the pristine audit.
# Rebuild and relink every codec consumer from source in a fresh scratch directory:
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=2 swift test \
  --package-path Packages/WaveWranglerKit \
  --scratch-path .build/lame-relink --jobs 2 --filter WWExportTests
# Rebuild the linked application too:
WW_JOBS=2 WW_DERIVED_DATA="$PWD/.build/LameRelinkDerivedData" scripts/build.sh Debug
```

All first-party application/wrapper source, package manifests, upstream library
source and rebuild scripts are available for this path. Preserve the LGPL user's
rights, including reverse engineering for debugging library modifications, and
do not impose additional restrictions on replacement builds. A binary release
must accompany its exact corresponding source/build materials and usable relink
instructions, not merely point to an upstream homepage or provide attribution.

`ExportLicensing` exposes the resource-bundled COPYING/LICENSE URLs for the later
About/licenses UI. Preserve other components' notices. **Release gate:** validate
the exact shipped source/relink package, application linkage, signing, sandbox,
library validation, distribution terms and any App Store terms before shipping.
This development foundation is not a claim of legal or App Store clearance.

## Generated-PCM qualification

```sh
umask 022
WW_JOBS=2 WW_TEST_WORKERS=2 SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=2 \
  swift test --package-path Packages/WaveWranglerKit \
  --scratch-path .build/swiftpm --jobs 2 --filter WWExportTests
python3 scripts/check-lame-source.py
```

Tests generate tones, encode/reopen/decode every exposed rate/channel/PCM
representation, cover AAC bitrates and MP3 CBR/VBR, check PCM sample precision,
signal energy, metadata/artwork roundtrips, invalid options/audio/destinations,
terminal lifecycle, cleanup and truncated-output rejection. No GUI tests are used.
Job tests additionally exercise the real production renderer, multi-format
single-render output, signed origins, duration/downmix, 16/24-bit TPDF,
cancellation/staleness, overload, collisions/partial publication, protected paths
and replaced-staging cleanup refusal. Unhosted `ExportMetadataAdapterTests`
qualify inheritance, export-only overrides and explicit omission confirmation.
These do not replace later document/native-editor/transport VM qualification.
Every CBR MP3 audio packet must carry the selected bitrate. AAC's measured audio
bitrate is qualified within 5% of each selected target over two seconds of generated
signal; nominal bitrate is not an exact short-file size promise.
