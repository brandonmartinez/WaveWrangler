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
decoder output.

`WWDecode.SourceDecoder.readVerifiedPCMWindow` now provides a **package-only
source-content primitive**, not a selected-Primary receipt. It uses the existing
read-only `withDecodingCursor` gateway, checks the decoded 16 kHz channel and
32,000-frame source coordinate window, consumes through EOF to catch an incomplete
tail, and returns only after the final descriptor/path staleness check. It caps
admitted source lengths at 10 minutes and holds only one decode chunk and one
window in memory. The returned interpretation contains the gateway-observed
fingerprint, but its logical source ID and URL still originate with the caller:
neither this type nor a matching synthetic identity establishes canonical
source selection, occurrence, epoch, accepted-map revision, or current publication.
There is no public speech call path to this package primitive.

**STOP before runtime activation:** establish an app-owned, exact-publication
selection issuer that binds the gateway-observed source descriptor to the
current show and source revision, accepted-map occurrence/epoch and chosen
channel. Recheck selection and those identities after decode and before
publication; never turn the caller-provided ID or the content primitive into
a credential. Keep Backup inactive and invalidate results
when confirmation or revision changes. Separately qualify the consented model,
effective no-network sandbox, and actual selected-Primary source under the
applicable gates. No media/model or native validation is claimed here. The initial
five synthetic `SelectedPrimaryPCMIngressTests` passed on the earlier clean head.
The five generated `VerifiedSourcePCMWindowTests` passed on this change's
pre-commit worktree with a focused package selector; the full exact-head suite
is **NOT RUN**. Neither focused run establishes production source authorization.
