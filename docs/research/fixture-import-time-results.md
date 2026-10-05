# Synthetic import/time descriptor results — bounded continuation

> **Publication notice:** This report describes archived historical evidence and phase permissions, not current execution authority. Public JSON companions are pointer-redacted and **NOT byte-identical archived mirrors**; [original versus published hashes](../planning/publication-provenance.json) are separate. Measurements, pins, artifact hashes, counts and failed controls remain unchanged. Local archive placeholders are not browsable repository links. [Current user-directed milestone policy](../planning/milestone-runbook.md) supersedes old no-issues/research-only phase restrictions without granting input consent.

**2026-10-04 · LOCAL partial evidence · integration owner: Lead.** Requested by Brandon Martinez (@brandonmartinez).

This surfaces Pipeline's existing `fixture-import-time-v1` descriptor-only evidence. This persistence pass performs no generation, numerical rerun, compilation or application execution.

## Finite results

- **64 synthetic descriptors:** 40 valid accepted; 24 expected faults correctly rejected; 64/64 case outcomes passed.
- **Frozen split:** calibration 16 (10 valid / 6 invalid); holdout 48 (30 valid / 18 invalid), with no calibration/holdout tuning.
- **One generated run:** 9,954/9,954 finite assertions passed, zero failures, exit 0 and empty stderr.
- **Permission/provenance/version envelopes:** 64/64 passed; intentional nested faults remain explicit.
- Queries: 640 supported numerical, 400 unsupported, 240 raw-frame bookkeeping and 80 occurrence guards.
- Coordinate checks use independent integer algebra, `Fraction` and `Decimal`; `1e-60` seconds/source-frame tolerance is arithmetic-only, not a DSP or real-audio accuracy threshold.
- **Joint coverage: 40/3,840 valid cells; 3,800 UNCOVERED.** Marginal/pair coverage does not establish the full matrix; calibration has no valid FLAC/FLAC-optional descriptor.

## Retained scratch evidence

Exact artifact root: `<research-artifacts>/research/fixture-import-time-v1/`.

SHA256 anchors below are transcribed from the existing final artifact-integrity ledger, not a fresh numerical validation. Frozen inputs and proof bytes are unchanged.

| Exact scratch artifact | Bytes | Ledger SHA256 |
| --- | ---: | --- |
| HANDOFF.md (`<research-artifacts>/research/fixture-import-time-v1/HANDOFF.md`; local archive) | 767 | `bbe062f71c7603fa21d9f7071bb0bdd7187d26e3b737ab24025d9ac3c8e20028` |
| results.json (`<research-artifacts>/research/fixture-import-time-v1/results.json`; local archive) | 63,575 | `e0ddf84b9deb7e1a98252d9a327c8e88dbce0ed92f4c4dd2b30c10e8544f3160` |
| manifest.json (`<research-artifacts>/research/fixture-import-time-v1/manifest.json`; local archive) | 461,820 | `c0e614163791e2bdf4a1de9f9d6d59b529db9b962c828d52fdf98e470d0613c3` |
| truth.json (`<research-artifacts>/research/fixture-import-time-v1/truth.json`; local archive) | 1,047,275 | `170cdcd934d808c6158e6ed133fee48fb26ed9d12ecdf51e7ad43d0db5482808` |
| freeze.json (`<research-artifacts>/research/fixture-import-time-v1/freeze.json`; local archive) | 3,826 | `be16e01bc461151d20dff4e08575fa64ee460287440d8e7e37364c134b9fd21b` |

artifact-integrity.json (`<research-artifacts>/research/fixture-import-time-v1/artifact-integrity.json`; local archive) records the final file seal and run summary; its own hash is deliberately excluded to avoid recursion.

## Limits and unchanged disposition

No audio samples/bitstreams, decoding, codec/container parsing or codec-support claim; no channel rendering, real timing/priming/padding validation, DSP, ASR, provider/cloud, GUI/accessibility, performance or production evidence. Candidate format labels are descriptors, not supported imports.

**WW-003 remains PARTIAL; WW-005/WW-049 remain PARTIAL unchanged.** No new WW IDs, broader completion or framework/decoder/time-policy adoption. The closed v3 UI history and its failures remain separate and unchanged.
