# Engineering

Current implementation contracts and development procedures. Start with
[CONTRIBUTING](../../CONTRIBUTING.md) for human contribution workflow or
[AGENTS](../../AGENTS.md) for coding-agent rules.

| Guide | Use it for |
| --- | --- |
| [Getting started](getting-started.md) | Toolchain, build, install, signing and isolated build output |
| [Architecture](architecture.md) | Module boundaries, native document/window ownership and feature routing |
| [Testing](testing.md) | Package/unhosted/hosted/UI layers, focused checks, concurrency and manual CI |
| [Persistence and source access](persistence-and-source-access.md) | Schemas, migration, publication/recovery, Undo, source authorization and immutable originals |
| [Audio processing](audio-processing.md) | Rendering, production versus diagnostic audio, effects, transport and caches |
| [Automatic alignment](automatic-alignment.md) | Acoustic proposals, adaptive provenance, acceptance and limits |
| [Program timeline](program-timeline.md) | Exact coordinates, cuts, insertions, clips, envelopes and production bounds |
| [Transcription](transcription.md) | Local models, worker admission, chunking, timing and review provenance |
| [Export codecs](export-codecs.md) | Encoding, metadata, loudness, delivery jobs, cleanup and licensing gates |
| [GUI testing](gui-testing.md) | Test plans, build/stage/run/collect pipeline and qualification scope |
| [UI-test VM hosts](ui-test-vm-hosts.md) | Host readiness, leases, process lifetime and physical-host exceptions |
| [GUI flake quarantine](gui-flake-quarantine.md) | Narrow test-selection exception and honest failure reporting |

Implementation source and tests are authoritative when behavior changes.
Update the focused reference with the code rather than appending a dated
handoff to this index.

[Source-tree baselines](../../test-support/qualification/source-tree-baselines.json) pin maintained source trees
and unchanged historical freeze records. They are integrity checks, not new
DSP qualification. Retained executable records and their relocation policy are
documented in [test support](../../test-support/README.md). Historical results
do not authorize experiments, user-media access, Git actions or distribution.
