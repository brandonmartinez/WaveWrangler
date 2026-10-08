### 2026-10-08: Provisional aligned-render envelope, not M3 acceptance
**By:** Alignment
**What:** Bound shared admission at 512 MiB; account for all retained channels, store staging and cursor buffers with checked arithmetic. Refuse unmeasured render rates, concurrency, decoder chunks, map complexity and oversized aggregate result sets before opening render cursors. Four-input and seven-channel short segments remain supported.
**Why:** The earlier 180-second six-channel measurement alone cannot establish the 1 GiB whole-process bound for every admitted shape. The scope is provisional, not an approved product cap or a #235 gate pass; more isolated boundary/multi-shape measurements and streaming publication are needed.
