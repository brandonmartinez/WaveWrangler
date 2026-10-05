# Project Context

- **Owner:** Brandon Martinez
- **Project:** WaveWrangler, a local-first macOS utility for preparing multitrack podcast recordings for a DAW
- **Stack:** Audio synchronization, drift modeling/correction, resampling, channel integrity, measurable quality validation
- **Created:** 2026-10-04T00:32:38.878-04:00

## Learnings

- Current delivery policy (2026-10-04): follow live GitHub milestones/issues and the milestone runbook under a named kickoff; earlier research-only entries are historical.
- Preserve the waveform candidate's 2/6 acoustic false accepts and distinguish acoustic consistency from clock approval. Never quietly relax quality/protection gates.
- M2 supplies aligned assets but no early uncut handoff; first audio handoff is the full cleaned-track M4 MVP.

- Initial operating mode is research and planning only.
- Alignment owns recorder grouping, offsets, inter-device drift correction, and DSP quality metrics.
- Outputs must be testable options and interface requirements, not app UI or transcript behavior.
- Preserve source audio and define measurable validation before recommending an approach.
