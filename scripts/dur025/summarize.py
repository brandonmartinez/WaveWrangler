#!/usr/bin/env python3
"""Summarise a DUR-025 run (scripts/dur025/run.py output) for the evidence document.

Usage: scripts/dur025/summarize.py .build/dur025/<split>/results.jsonl [.build/dur025/<split>/run-record.json]
Percentiles are nearest-rank (registry rule). Every case is listed; nothing is dropped.
"""
import collections
import json
import math
import sys


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
    print("| Cell | Cases | Pass | Fail | Harness error |")
    print("|---|---:|---:|---:|---:|")
    for cell in ["show", "library", "relink", "recovery"]:
        cases = by_cell.get(cell, [])
        verdicts = collections.Counter(r["verdict"] for r in cases)
        print(f"| {cell} | {len(cases)} | {verdicts['pass']} | {verdicts['fail']} | {verdicts['harnessError']} |")
    print()
    for cell in ["show", "library"]:
        cases = by_cell.get(cell, [])
        if not cases:
            continue
        print(f"### {cell}")
        paths = collections.Counter(json.dumps(r.get("detectionPath"), sort_keys=True) for r in cases)
        print("- detection paths: " + "; ".join(f"{k} ×{v}" for k, v in paths.most_common()))
        print("- hosts with a local acknowledgement: " + ", ".join(f"{k} host(s) ×{v}" for k, v in sorted(collections.Counter(len(r.get("localAcks", [])) for r in cases).items())))
        print(f"- time to settle (from trigger): {stats([r.get('timeToSettleMs') for r in cases])}")
        if cell == "show":
            for host in ("A", "B"):
                print(f"- time to surfacing on {host} (status count > 0): {stats([(r.get('timeToSurfacingMs') or {}).get(host) for r in cases])}")
            counts = collections.Counter(json.dumps(r.get("versionCounts"), sort_keys=True) for r in cases)
            print("- version counts per host (unresolved conflict / status / other): " + "; ".join(f"{k} ×{v}" for k, v in counts.most_common()))
        else:
            for host in ("A", "B"):
                print(f"- provider version observed on {host}: {stats([((r.get('timeToSurfacingMs') or {}).get('providerVersionObserved') or {}).get(host) for r in cases])}")
                print(f"- L4 on open on {host}: {stats([((r.get('timeToSurfacingMs') or {}).get('l4OnLoadAt') or {}).get(host) for r in cases])}")
            edits = collections.Counter(f"A:{r['edits']['A']} B:{r['edits']['B']}" for r in cases if r.get("edits"))
            print("- seeded edits: " + "; ".join(f"{k} ×{v}" for k, v in sorted(edits.items())))
            presence = collections.Counter(p for r in cases for host in (r.get("presence") or {}).values() for p in host.values())
            print("- presence of each Mac's change on each host after Combine: " + ", ".join(f"{k} ×{v}" for k, v in presence.items()))
            print(f"- conflict versions backed up before resolve: {sum(sum((r.get('conflictBackups') or {}).values()) for r in cases)} backups; unresolved left: {sum(r.get('unresolvedLeft') or 0 for r in cases)}")
        print(f"- A→B propagation of the setup revision: {stats([r.get('propagationAtoBMs') for r in cases])}")
        print()
    for cell in ["relink", "recovery"]:
        cases = by_cell.get(cell, [])
        if cases:
            variants = collections.Counter((r.get("variant") or "(not reached)", r["verdict"]) for r in cases)
            print(f"### {cell}: " + "; ".join(f"{v} {verdict} ×{n}" for (v, verdict), n in sorted(variants.items())))
    failures = [r for r in rows if r["verdict"] != "pass"]
    print()
    print(f"### Failures and harness errors: {len(failures)}")
    for r in sorted(failures, key=lambda r: r["caseIndex"]):
        print(f"- case {r['caseIndex']} ({r['stratum']}): {r['verdict']} — " + json.dumps({k: v for k, v in r.items() if k not in ('seed',)}, sort_keys=True)[:600])
    if record:
        print()
        print("### Run record")
        for key in ("commit", "requiredCommits", "probeSha256", "startedAt", "finishedAt", "clockOffsetStart", "clockOffsetEnd", "trees", "hosts", "cleanup", "label"):
            print(f"- {key}: {json.dumps(record.get(key), sort_keys=True)}")


if __name__ == "__main__":
    main()
