### 2026-10-09: Bound provisional common-edit structural inspection
**By:** Alignment
**What:** Refuse above 16 lanes/surveys, 65,536 grid-frame/survey checks, 131,072 worst-case inverse calls, 32 intervals per survey array and 256 intervals across every survey lane; keep the upstream map metadata caps aligned with provisional keyed-cut mapping. Leave attestation always refusing.
**Why:** The old 8,192-frame limit still permitted unbounded channel fanout and interval scans. These checked aggregate ceilings make synthetic structural inspection finite without silently omitting lanes or claiming production capacity or source authority.
