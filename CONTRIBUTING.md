# Contributing to WaveWrangler

WaveWrangler is a native, sandboxed macOS audio editor. Its portable documents
hold user decisions; recordings stay immutable, inference stays local, and
derived caches never become permission or document authority.

Start with [getting started](docs/engineering/getting-started.md), then use the
[engineering index](docs/engineering/README.md) to find the relevant contract.
Automation and coding agents must also read [AGENTS.md](AGENTS.md).

## Development setup

Use an Apple Silicon Mac running macOS 26 or newer, full Xcode with the macOS
26 SDK or newer, and Swift tools 6.2 or newer. The project uses Swift 6 language
mode and arm64 targets. Command Line Tools alone do not build the app.

From the repository root:

```sh
WW_JOBS=2 WW_DERIVED_DATA="$PWD/.build/DevelopmentDerivedData" scripts/build.sh Debug
umask 022
WW_JOBS=2 WW_TEST_WORKERS=2 \
  WW_DERIVED_DATA="$PWD/.build/TestDerivedData" scripts/test.sh
```

The test command runs generated native timestamp checks, package tests and
bounded specialized passes, then unhosted app tests. It does not launch the app.
See [testing](docs/engineering/testing.md) for focused checks and VM-only
hosted/UI execution. Keep the editing app's build separate from test builds.
For a verified local installation, use `scripts/install-local.sh`; never build
with `sudo`. The [setup guide](docs/engineering/getting-started.md) explains
installation, signing and first-launch prerequisites.

## Making a change

1. Establish the requested behavior and its limits. Inspect the current code,
   tests and relevant engineering reference before designing a replacement.
2. Check the working tree. Preserve unrelated work and coordinate ownership
   when sharing a checkout. Do not mix an unrelated cleanup into a feature fix.
3. Implement the whole feature path: validated domain state, persistence and
   dependency invalidation where applicable, document transaction, native
   interface, and focused regression coverage.
4. Run the smallest checks that exercise the changed contract, then broaden
   validation when cross-layer behavior requires it. Record blocked or skipped
   coverage honestly; compilation is not a native interaction test.
5. Update the current user/developer documentation with the change. Remove
   superseded instructions rather than appending another phase diary.
6. Submit a reviewable change describing behavior, compatibility, validation
   scope and unresolved limitations. Follow the agreed issue/branch/commit
   workflow; documentation and old handoffs do not grant Git permissions.

CI is [manual-only](.github/workflows/README.md). Do not add automatic triggers,
release publishing or agent dispatch as an incidental improvement.

## Complete feature patterns

| Change | Follow the whole path |
| --- | --- |
| Saved property | Add a typed `WWCore` value and validated operation; update strict coding, schema/migration and recovery expectations; apply through `ShowDocumentStore`; test roundtrip, migration, multiwindow updates and Undo/Redo. |
| Source or import behavior | Keep review metadata-only; obtain explicit authorization; admit through `WWSources` and `WWDecode`; recheck live identity/access; publish canonical state and conditionally adopt only owned access records. Test refusal, cancellation and postpublication failure. |
| Long-running analysis | Capture scoped inputs, admit bounded resources, check cancellation during work, and revalidate source/map/document currency before publishing. Preserve unrelated live edits and reject stale/ABA results. |
| Audio processing or effect control | Use the shared program projection and existing runtime/mixer; distinguish raw media from processing dependencies; retain native-state barriers, verified saves and bounded playback. Test actual rendered output, not waveform appearance alone. |
| Native control or window | Keep one canonical document and Undo manager; bind the logical episode; support keyboard/VoiceOver and non-drag actions; test lifecycle and shared ownership in the leased VM. |
| Export behavior | Use the existing offline renderer and verified codec/job pipeline; preserve exact omission consent, no-overwrite publication, partial receipts and throwing cleanup. Check linked notices and release licensing separately. |

The architecture and boundary details live in
[architecture](docs/engineering/architecture.md),
[persistence and source access](docs/engineering/persistence-and-source-access.md),
[audio processing](docs/engineering/audio-processing.md), and
[export codecs](docs/engineering/export-codecs.md).

## Review standards

Use small focused types, composition, Swift 6 isolation and Sendable value
snapshots. Keep domain operations pure and throwing rather than partially
mutating. Use American English for first-party names and prose, but preserve
platform APIs, third-party bytes, serialized names and quoted evidence.

Review failure paths as carefully as success: unknown is not missing, canceled
is not completed, prepared is not authorized, and published is not necessarily
verified. Check multiple windows, Undo/Redo, deletion, equal-byte restoration,
source revocation, effect capture, and late asynchronous completion when relevant.
Do not silently recover by substituting a source, default channel, old cache,
empty result, or clipped audio.

Tests ordinarily use generated media in temporary directories. Do not open user
recordings, download models, run live-provider trials or rerun frozen experiments
without separate authorization. A historical result is evidence about its exact
inputs, not proof about a changed implementation.

## Documentation and licensing

Keep contributor setup here, agent rules in [AGENTS.md](AGENTS.md), and technical
contracts in focused [engineering references](docs/engineering/README.md).
User-facing instructions belong with the product documentation, not in source
comments or engineering run logs. Retained executable qualification records are
explained in [test support](test-support/README.md).

First-party licensing does not relicense bundled dependencies. Preserve upstream
source bytes and notices, including Whisper and LAME. LAME's LGPL obligations
include corresponding source and usable rebuild/relink rights, not attribution
alone. Test signing and VM results do not clear commercial distribution or the
Mac App Store: the [release gate](docs/engineering/export-codecs.md#licensing-and-release-gate)
requires release-specific technical and legal review.
