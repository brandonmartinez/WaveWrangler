# Export codec foundation

`WWExport` is independent of the document and mixer. It accepts already converted,
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
The later job layer must decide conversion, headroom and clipping policy explicitly;
normalization Off can preserve levels exactly through floating-point WAV.
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
# Once the application phase links WWExport, rebuild the application too:
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
Every CBR MP3 audio packet must carry the selected bitrate. AAC's measured audio
bitrate is qualified within 5% of each selected target over two seconds of generated
signal; nominal bitrate is not an exact short-file size promise.
