#!/usr/bin/env python3
"""Summarise a DUR-025 run (scripts/dur025/run.py output, m1-freeze-3/-4) for the evidence document.

Usage: scripts/dur025/summarize.py .build/dur025/<split>/results.jsonl [.build/dur025/<split>/run-record.json]
Percentiles are nearest-rank (registry rule). Every case is listed; nothing is dropped. Counted slots are the
evaluated cases (pass/fail); setupNotEstablished cases are reported separately with their refills.
"""
import collections
import json
import math
import sys

CELLS = ["show", "library", "relink", "recovery"]


def pct(values, p):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    return values[max(0, min(len(values) - 1, math.ceil(p * len(values)) - 1))]


def stats(values):
    vals = [v for v in values if v is not None]
    if not vals:
        return "n=0"
    return f"n={len(vals)} p50 {pct(vals, .5) / 1000:.1f} s · p95 {pct(vals, .95) / 1000:.1f} s · max {max(vals) / 1000:.1f} s"


def main():
    rows = [json.loads(line) for line in open(sys.argv[1])]
    record = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else {}
    by_cell = collections.defaultdict(list)
    for row in rows:
        by_cell[row["stratum"]].append(row)
    incomplete = record.get("cellsIncomplete", {})
    print("| Cell | Evaluated | Pass | Fail | setupNotEstablished | Of the fails: harness error | Cell |")
    print("|---|---:|---:|---:|---:|---:|---|")
    for cell in CELLS:
        cases = by_cell.get(cell, [])
        v = collections.Counter(r["verdict"] for r in cases)
        evaluated = v["pass"] + v["fail"]
        status = f"INCOMPLETE ({incomplete[cell]})" if cell in incomplete else ("pass" if cases and v["fail"] == 0 else "FAIL" if cases else "-")
        harness = sum(1 for r in cases if r.get("harnessError"))
        print(f"| {cell} | {evaluated} | {v['pass']} | {v['fail']} | {v['setupNotEstablished']} | {harness} (counted as fail) | {status} |")
    print()
    for cell in CELLS:
        cases = by_cell.get(cell, [])
        if not cases:
            continue
        variants = collections.Counter((r.get("variant") or "-", r["verdict"]) for r in cases)
        print(f"### {cell}")
        print("- variants: " + "; ".join(f"{v} {verdict} ×{n}" for (v, verdict), n in sorted(variants.items())))
        refills = [r for r in cases if r.get("reserveIndex") is not None]
        if refills:
            print("- reserve refills: " + "; ".join(f"slot {r['slot']} ← {r['split']} #{r['reserveIndex']} ({r['verdict']})" for r in refills))
        waits = [w for r in cases for w in r.get("setup", {}).get("waits", [])]
        retries = [w for w in waits if w["attempt"] == 2]
        print(f"- setup waits: {len(waits)} ({len(retries)} after a download request); first-product-operation order OK in "
              f"{sum(1 for r in cases if r.get('setupWaitsBeforeFirstProductOperation'))}/{len(cases)}")
        print(f"- time to settle: {stats([r.get('timeToSettleMs') for r in cases])}")
        print(f"- setup wait per fixture (until observed on host B): {stats([w.get('waitedMs') for w in waits if w.get('observed')])}")
        if cell in ("show", "library"):
            paths = collections.Counter(json.dumps(r.get("detectionPath"), sort_keys=True) for r in cases if r["verdict"] != "setupNotEstablished")
            print("- detection paths: " + "; ".join(f"{k} ×{v}" for k, v in paths.most_common()))
            print("- hosts with a local acknowledgement: " + ", ".join(f"{k} ×{v}" for k, v in sorted(collections.Counter(len(r.get("localAcks", [])) for r in cases).items())))
        if cell == "show":
            counts = collections.Counter(json.dumps(r.get("versionCounts"), sort_keys=True) for r in cases if r.get("versionCounts"))
            print("- version counts per host: " + "; ".join(f"{k} ×{v}" for k, v in counts.most_common()))
        if cell == "library":
            sampled = [r for r in cases if r.get("levelSampling")]
            for host in ("A", "B"):
                f4 = sum(r["levelSampling"][host]["freeze4Fails"] for r in sampled)
                lit = sum(r["levelSampling"][host]["literalFreeze3Fails"] for r in sampled)
                held = sum(r["levelSampling"][host]["holding"] for r in sampled)
                gap = max([r["levelSampling"][host]["maxGapWhileHoldingMs"] or 0 for r in sampled] or [0])
                print(f"- level samples on {host}: holding {held}; freeze-4 FAIL samples {f4}; literal freeze-3 FAIL samples {lit}; "
                      f"max gap while holding {gap / 1000:.1f} s")
            per_case = [(r["caseIndex"], {h: r["levelSampling"][h]["literalFreeze3Fails"] for h in ("A", "B")}) for r in sampled
                        if any(r["levelSampling"][h]["literalFreeze3Fails"] for h in ("A", "B"))]
            print(f"- cases with literal freeze-3 FAIL samples: {per_case or 'none'}")
            disagreements = sum(1 for r in sampled for h in ("A", "B") for s in r.get("levelSamples", {}).get(h, []) for v in s["versions"] if v.get("disagreement"))
            print(f"- product/harness inclusion disagreements (version samples): {disagreements}")
            rounds = collections.Counter(len(r.get("rounds", [])) for r in cases if r.get("rounds"))
            print("- Combine rounds: " + ", ".join(f"{k} ×{v}" for k, v in sorted(rounds.items())))
            checks = [c for r in cases for c in r.get("summaryChecks", [])]
            print(f"- Combine summary checks: {sum(1 for c in checks if c.get('ok'))}/{len(checks)} OK")
            presence = collections.Counter(p for r in cases for per in (r.get("presence") or {}).values() for p in per.values())
            print("- presence of each Mac's change on each host: " + ", ".join(f"{k} ×{v}" for k, v in presence.items()))
            print(f"- settle clause OK: {sum(1 for r in cases if r.get('settleClause') and all(c['ok'] for c in r['settleClause'].values()))}/"
                  f"{sum(1 for r in cases if r.get('settleClause'))}")
    failures = [r for r in rows if r["verdict"] not in ("pass",)]
    print()
    print(f"### Not passed: {len(failures)}")
    for r in sorted(failures, key=lambda r: (r["split"], r["caseIndex"])):
        print(f"- {r['split']} #{r['caseIndex']} ({r['stratum']}/{r.get('variant')}): {r['verdict']} — {r.get('reason', '')}"
              + (f" [stalled fixture: {r.get('stalledFixture')}]" if r.get("stalledFixture") else ""))
    if record:
        print()
        print("### Run record")
        for key in ("split", "commit", "requiredCommits", "freeze", "startedAt", "finishedAt", "clockOffsetStart", "clockOffsetEnd",
                    "hosts", "trees", "setupNotEstablished", "setupNotEstablishedCap", "cellsIncomplete", "reserveIndicesUsed", "cleanup"):
            print(f"- {key}: {json.dumps(record.get(key), sort_keys=True)}")


if __name__ == "__main__":
    main()
