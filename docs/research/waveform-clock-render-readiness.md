# Waveform clock estimation and render readiness

> **Publication notice:** This report describes archived historical evidence and phase permissions, not current execution authority. Public JSON companions are pointer-redacted and **NOT byte-identical archived mirrors**; [original versus published hashes](../planning/publication-provenance.json) are separate. Measurements, pins, artifact hashes, counts and failed controls remain unchanged. Local archive placeholders are not browsable repository links. [Current user-directed milestone policy](../planning/milestone-runbook.md) supersedes old no-issues/research-only phase restrictions without granting input consent.

**2026-10-04 · Alignment execution; Lead review; parent publication.**
**Disposition: partial synthetic evidence; the WW-016 acoustic-negative gate FAILED.**
[Exact results](waveform-clock-render-readiness-results.json) · [reconciliation](parallel-readiness-reconciliation.md).

## Scope and reproducibility

This integrates Alignment's source report, not an independent reproduction.
New actual generated PCM/WAV, estimator, scorer, original failures and frozen inputs remain at:

```text
<research-artifacts>/research/parallel-readiness-20261004/alignment/
```

`PROTOCOL.md`, `FREEZE.json`, `CHRONOLOGY.json`, `Candidate.swift`, `truth.py`, `independent_score.py` and `raw/scored-all.json` describe the exact experiment.
The native candidate estimates from **waveform content**, not supplied truth anchors.
Truth and scoring use separate construction paths but share an author; no statistical independence or real-recording qualification is claimed.

Two calibration pairs precede ten qualification pairs. Each pair has two recorder groups, unequal starts and six shared-clock channels.
Cases include affine drift, mixed rates, noise/bleed, a capture gap, a discontinuity, silence, periodic/unrelated content and acoustic-delay confounds.
Twenty-five fresh input WAVs were generated; no user media or listening was involved.

## Estimator findings

AVAudioFile decodes PCM; channel 0 feeds a 4-kHz proxy and normalized `vDSP_convD` correlations.
Thirteen windows, parabolic peak refinement and an affine fit use fixed RMS/peak/margin/residual/coverage gates.
Scores remain diagnostics, not calibrated probabilities.

The unchanged clock target is p95 <=5 ms, maximum <=10 ms, at least five windows, span >=80%, eligible coverage >=60%, **zero negative false accepts**.

| Qualification subset | Actual outcome |
| --- | --- |
| Four positive pairs | 4/4 meet clock targets; worst maximum error 0.007505 ms. |
| Discontinuity, unrelated, silent and periodic negatives | 4/4 abstain; no discontinuity repair or general piecewise-map proof. |
| Constant 35-ms acoustic delay | **False accept**, approximately 35.0065-ms maximum clock error. |
| Variable acoustic delay | **False accept**, approximately 44.2199-ms maximum clock error. |

**Overall: 2/6 negatives falsely accept, so WW-016's candidate gate fails.**
Strong peaks and small fit residuals cannot distinguish selected acoustic propagation delay from a changed recorder clock.
The variable-delay negative has stronger confidence than positive cases.
This is not cured by silently raising a score threshold or treating human acceptance as oscillator truth.

The indistinguishability applies to the selected content channels; diagnostic tone channels were not used by the estimator.
It is not a proof that every possible multi-channel algorithm is equally ambiguous.
The actionable interface separates an **acoustic-consistent proposal** from a clock-approved/manual/external-evidence map.

## Executed multi-channel rendering

The candidate uses one group transform on every channel: `u=n/Fin+e`, `t=a*u+b`, output/input ratio `a*Fout/Fin`, supported inverse `n=Fin*((t-b)/a-e)`.
Clip epoch/origin and gaps are explicit; analysis downmix/gain does not enter render inputs.
Clock correction is not pitch-preserving time stretch.

Renderer: a **64-tap Blackman-windowed sinc candidate**, not a qualified production SRC.
Six positive render jobs produce six-channel 48-kHz/24-bit WAV, **1,008,000 frames / 21 seconds** each.
Exercised decode: six-channel 16-bit PCM WAV at 12/16 kHz; rendered inputs are 16 kHz only.
No compressed-format, BWF, broader codec or 12-to-48-kHz render claim follows.

| Measured positive-render property | Finite result |
| --- | --- |
| Shape, common origin/duration and support padding | 6/6 exact; complete leading/trailing/gap padding audited. |
| Source-coordinate conformance to the declared estimated map | Maximum 5.820766e-11 source frames. |
| Independent clock inverse | Maximum 0.119902 source frames across four positive maps, outside gaps. |
| Actual content landmarks | 12/12 measured shifts zero output frames; not long-form coverage. |
| Channel relations | Retained order/sign/scaling; additional skew zero in five relational fixtures. |
| Inactive channel | Exact digital zero; represented -80-dBFS gate passes. |
| Tone relative phase | Maximum 0.020833 degrees, below fixture-frozen 0.5 degrees. |

Excellent channel metrics **do not validate the clock**: the accepted acoustic negatives also render, with wrong content timing.
Separate retained faulty render controls detect channel swap, inversion, inactive leakage, inverse-slope misuse and wrong origin.
The wrong-origin landmark search is range-limited; its raw winner is unsupported, while independent map failures reject it.
Differences against a separate 128-tap reference are measurements, not complete spectral/alias/listening qualification.

## Corrections and accounting

One native compile and one native test process; no installs or GUI.
The second bounded cycle fixes only a later byte-padding audit's floating-point `ceil` error using Decimal.
The original failed audit remains; estimator, thresholds, scorer inputs and rendered outputs were not tuned or rerun.
Freeze precedes qualification; all 34 frozen entries remain unchanged.

Host: macOS 27.0.1/arm64/128 GiB, Swift 6.4 and Python 3.14.8.
Build targets the host, **not macOS 26**. No 16-GB, long-duration, streaming, thermal or listening qualification.
Primary API evidence is retained in `SOURCES.json`: [vDSP convolution](https://developer.apple.com/documentation/accelerate/vdsp_convd), [AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile), and [TN3136 sample-rate conversion](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions).

## Owned action

**Alignment, Lead review recommended 2026-10-05:** define clock-approval provenance/manual fallback and a shared renderer/recipe adapter.
Qualify spectral/alias/phase/listening, broader rates/codecs, restarts/gaps/multi-group cycles and the reference device before stronger claims.
No new trial or threshold change is authorized here.
WW-003/015/016/017 remain partial; WW-018/050 receive candidate evidence while pending.
