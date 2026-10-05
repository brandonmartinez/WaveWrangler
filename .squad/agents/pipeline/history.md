# Project Context

- **Owner:** Brandon Martinez
- **Project:** WaveWrangler, a local-first macOS utility for preparing multitrack podcast recordings for a DAW
- **Stack:** Local speech processing to be evaluated; word timing, non-destructive edit semantics, synchronized editable-track export
- **Created:** 2026-10-04T00:32:38.878-04:00

## Learnings

- Current delivery policy (2026-10-04): live GitHub milestones/issues and the milestone runbook supersede the initial research-only phase; work only within the named kickoff.
- Retain offline tokenizer fallback, merged-fade final-footprint and source-reconstruction/SRC limits. Human acceptance and protected-speech gates remain mandatory.
- Model/native provisioning, recording access and external publication require exact consent; the configuration commit starts none of them.

- Initial operating mode is research and planning only.
- Pipeline owns speaker-primary selection, transcription, timing, filler suggestions, cut review, and edit representation.
- Outputs define semantics and model evaluations, not DSP correction or general macOS architecture.
- Machine suggestions must remain distinguishable from user-approved edits.
