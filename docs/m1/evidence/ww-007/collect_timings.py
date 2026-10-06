#!/usr/bin/env python3
"""Collect WW-007 native timing samples (M1-SCALE-001 native) from a UI-test run.

Usage: collect_timings.py <xcodebuild-ui-test.log> [--json out.json] [--raw raw.jsonl]

The app (Debug, `-WWUITestTimingLog YES`) logs one `WWTIMING` line per interval (WaveWrangler/Support/
Responsiveness.swift: input event timestamp -> end of the run-loop pass that committed the change). The
sandboxed UI-test runner can't read the unified log, so it prints `[phase] begin|end <name> <epoch>` markers;
this script reads the app's lines with `log show` and assigns them to phases by time.

Statistics: nearest-rank percentile ceil(p*n) (registry rule), p95 and max reported for every stratum.
"""
import argparse
import datetime as dt
import json
import math
import re
import subprocess
import sys

STRATA = {
    # phase: [(stratum, timing name, filter)]
    "cold-first-open": [("launchToLibraryReady", "launch.libraryReady", None, 1000),
                        ("firstOpenCold", "show.open", lambda d: d.get("openIndex") == "1", 1000)],
    "warm-reopen": [("warmOpen", "show.open", lambda d: int(d.get("openIndex", "0")) >= 2, 1000)],
    "interaction-library-sidebar": [("librarySidebarSelection", "library.sidebarSelection", None, 100)],
    "interaction-collection-edit": [("collectionEdit", "library.edit", None, 100)],
    "interaction-episode-switch": [("episodeSwitch", "show.sidebarSelection", None, 100)],
    "interaction-metadata-edit": [("metadataEdit", "show.edit", None, 100)],
}
INTERACTIONS = ["librarySidebarSelection", "collectionEdit", "episodeSwitch", "metadataEdit"]


def percentile(values, p):
    ordered = sorted(values)
    rank = math.ceil(p * len(ordered))
    return ordered[max(0, min(len(ordered) - 1, rank - 1))]


def summary(values, gate):
    if not values:
        return {"n": 0, "gateMs": gate, "gatePassed": False}
    p95 = percentile(values, 0.95)
    return {"n": len(values), "p50": round(percentile(values, 0.5), 3), "p95": round(p95, 3),
            "max": round(max(values), 3), "min": round(min(values), 3), "gateMs": gate, "gatePassed": p95 < gate,
            "overGate": sum(1 for v in values if v >= gate)}


def phases(log_text):
    found, open_ = [], {}
    for match in re.finditer(r"\[phase\] (begin|end) (\S+) ([0-9.]+)", log_text):
        kind, name, epoch = match.group(1), match.group(2), float(match.group(3))
        if kind == "begin":
            open_[name] = epoch
        elif name in open_:
            found.append((name, open_.pop(name), epoch))
    return found


def app_timings(start, end):
    fmt = "%Y-%m-%d %H:%M:%S"
    args = ["log", "show", "--style", "ndjson", "--info",
            "--start", dt.datetime.fromtimestamp(start - 2).strftime(fmt),
            "--end", dt.datetime.fromtimestamp(end + 2).strftime(fmt),
            "--predicate", 'subsystem == "com.brandonmartinez.wavewrangler" AND category == "Responsiveness"']
    out = subprocess.run(args, check=True, capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        message = obj.get("eventMessage", "")
        if not message.startswith("WWTIMING "):
            continue
        fields = dict(part.split("=", 1) for part in message[len("WWTIMING "):].split() if "=" in part)
        stamp = dt.datetime.strptime(obj["timestamp"][:26], "%Y-%m-%d %H:%M:%S.%f")
        offset = obj["timestamp"][26:]
        sign = 1 if offset[0] == "+" else -1
        tz = dt.timezone(sign * dt.timedelta(hours=int(offset[1:3]), minutes=int(offset[3:5])))
        rows.append({"epoch": stamp.replace(tzinfo=tz).timestamp(), "name": fields.pop("name"),
                     "eventMs": float(fields.pop("eventMs")), "handlerMs": float(fields.pop("handlerMs")),
                     "thread": fields.pop("thread", "?"), "pid": obj.get("processID"), "detail": fields})
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("logs", nargs="+")
    parser.add_argument("--json")
    parser.add_argument("--raw")
    args = parser.parse_args()
    text = "".join(open(path, errors="replace").read() for path in args.logs)
    marked = phases(text)
    if not marked:
        print("no [phase] markers found", file=sys.stderr)
        return 1
    rows = app_timings(min(b for _, b, _ in marked), max(e for _, _, e in marked))
    result, raw = {}, []
    for phase, begin, end in marked:
        for stratum, name, keep, gate in STRATA.get(phase, []):
            picked = [r for r in rows if begin <= r["epoch"] <= end + 1.0 and r["name"] == name and (keep is None or keep(r["detail"]))]
            values = result.setdefault(stratum, {"values": [], "handler": [], "gate": gate, "threads": {}, "processes": set()})
            values["values"] += [r["eventMs"] for r in picked]
            values["handler"] += [r["handlerMs"] for r in picked]
            for r in picked:
                values["threads"][r["thread"]] = values["threads"].get(r["thread"], 0) + 1
                values["processes"].add(r["pid"])
                raw.append({"phase": phase, "stratum": stratum, **r})
    report = {}
    for stratum, data in result.items():
        report[stratum] = summary(data["values"], data["gate"])
        report[stratum]["handlerToCommit"] = summary(data["handler"], data["gate"])
        report[stratum]["threads"] = data["threads"]
        report[stratum]["processes"] = len(data["processes"])
    all_interactions = [v for s in INTERACTIONS if s in result for v in result[s]["values"]]
    report["allInteractions"] = summary(all_interactions, 100)
    print(json.dumps(report, indent=2))
    if args.json:
        with open(args.json, "w") as handle:
            json.dump(report, handle, indent=2)
    if args.raw:
        with open(args.raw, "w") as handle:
            for r in raw:
                handle.write(json.dumps(r) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
