# Provisional selected-Primary PCM ingress

`SelectedPrimaryPCMIngress.requireAuthorization` rejects an unselected or unconfirmed
channel and **also rejects every confirmed channel**: the canonical assignment alone
does not issue a source-owned receipt for the opened descriptor, current publication,
source revision, occurrence, proxy and decoded channel. Caller-provided IDs, bookmarks
and paths cannot substitute for that receipt. No app media opener, read or inference
entry point is added; `SpeechInference.infer` remains production-refusing.

The package-only `SyntheticPCMIngress` accepts generated `WWDecode.DecodedChunk`
values, checks matching *caller-supplied* source/revision/occurrence/proxy/channel
identities, contiguous source-frame coordinates, exactly 32,000 finite normalized
samples from one 16 kHz channel, bounded end arithmetic and cancellation. It can
feed the existing `BoundedPCMInference` input envelope in synthetic experiments.
This comparison is not authorization: the test values do not come from a trusted
issuer. It does not resample, seek, invent word timing/confidence or publish partial
decoder output. `SourceDecoder.withDecodingCursor` remains the sole source content
gateway and guards incomplete streams, identity, staleness and cancellation, but
it does not currently bind canonical selection/publication to a receipt.

**STOP before runtime activation:** establish an authoritative current-model
selection and source-owned, exact-publication receipt at the existing decode
gateway; bind occurrence, revision, proxy and channel to it and recheck selection
after decode and before publication. Keep Backup inactive and invalidate results
when confirmation or revision changes. Separately qualify the consented model,
effective no-network sandbox, and actual selected-Primary source under the
applicable gates. No media/model or native validation is claimed here; build and
Swift tests were **NOT RUN** while the timing-sensitive host gates were occupied.
