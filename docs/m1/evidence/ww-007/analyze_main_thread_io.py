#!/usr/bin/env python3
"""Summarise file-system calls made on WaveWrangler's main thread in an Instruments File Activity trace.

Usage: analyze_main_thread_io.py <trace> [--process WaveWrangler] [--json out.json]

Exports the FsSyscall table with `xctrace export`, resolves Instruments' id/ref value sharing, keeps rows for
the given process, and groups main-thread rows by path category. Paths are reduced to categories (and the
basename for synthetic fixture documents) so no user path is printed.
"""
import argparse
import re
import collections
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

XPATH = '/trace-toc/run[@number="1"]/data/table[@schema="FsSyscall"]'


def export(trace):
    out = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", XPATH],
                         check=True, capture_output=True).stdout
    return ET.fromstring(out)


def category(path):
    if not path:
        return "no path"
    if "/Data/tmp/WWUITestLibrary100" in path:
        return "show document (synthetic fixture)"
    if "/Library/Containers/com.brandonmartinez.wavewrangler/" in path:
        return "app container: " + "/".join(path.split("/Data/", 1)[-1].split("/")[:2])
    if path.endswith(".wwshow"):
        return "show document"
    if "/Library/Preferences/" in path:
        return "preferences"
    for prefix, name in (("/System/", "system"), ("/usr/", "system"), ("/Library/", "system library"),
                         ("/private/var/db/", "system db"), ("/dev/", "device"),
                         ("/private/var/folders/", "per-user temp/cache")):
        if path.startswith(prefix):
            return name
    if "/WaveWrangler.app/" in path or "/DerivedData/" in path or "/.build/" in path:
        return "app bundle / build products"
    if path.startswith("/Applications/"):
        return "other app bundles (Launch Services lookups)"
    if path == "Unknown Path" or path.startswith("C/Resources/"):
        return "unresolved / framework resources"
    return "other"


def home(path):
    # Per-user temp/cache directories carry a per-user random component: never print it.
    if re.search(r"(^|/)(private/)?var/folders/", path):
        return "<per-user temp>"
    parts = path.split("/")
    if len(parts) > 2 and parts[1] == "Users":
        return "~/" + "/".join(parts[3:])
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace")
    parser.add_argument("--process", default="WaveWrangler")
    parser.add_argument("--json")
    args = parser.parse_args()
    root = export(args.trace)
    values, raw_values = {}, {}
    for element in root.iter():
        if "id" in element.attrib:
            values[element.attrib["id"]] = element.attrib.get("fmt", element.text or "")
            raw_values[element.attrib["id"]] = element.text or ""

    def resolved(element):
        if element is None:
            return ""
        if "ref" in element.attrib:
            return values.get(element.attrib["ref"], "")
        return element.attrib.get("fmt", element.text or "")

    def number(element):
        if element is None:
            return 0
        raw = raw_values.get(element.attrib["ref"], "") if "ref" in element.attrib else (element.text or "")
        try:
            return int(raw)
        except ValueError:
            return 0

    schema = root.find(".//schema")
    columns = [col.findtext("mnemonic") for col in schema.findall("col")]
    rows = []
    for row in root.iter("row"):
        cells = dict(zip(columns, list(row)))
        if args.process not in resolved(cells.get("process")):
            continue
        rows.append({
            "syscall": resolved(cells.get("syscall")),
            "thread": resolved(cells.get("thread")),
            "path": resolved(cells.get("path")),
            "durationNs": number(cells.get("duration")),
        })
    main_rows = [r for r in rows if r["thread"].lower().startswith("main thread")]
    threads = collections.Counter(r["thread"].split(" 0x")[0] for r in rows)
    durations = collections.Counter()
    for r in main_rows:
        durations[category(r["path"])] += r["durationNs"]
    other = collections.Counter(home("/".join(r["path"].split("/")[:5])) for r in main_rows if category(r["path"]) == "other")
    by_category = collections.Counter(category(r["path"]) for r in main_rows)
    by_syscall = collections.Counter(r["syscall"] for r in main_rows)
    docs = sorted({r["path"].rsplit("/", 1)[-1] for r in main_rows if category(r["path"]).startswith("show document")})
    summary = {
        "processRows": len(rows),
        "mainThreadRows": len(main_rows),
        "threads": dict(threads.most_common(8)),
        "mainThreadByCategory": dict(by_category.most_common()),
        "mainThreadDurationMsByCategory": {k: round(v / 1e6, 3) for k, v in durations.most_common()},
        "mainThreadOtherPathPrefixes": dict(other.most_common(10)),
        "mainThreadBySyscall": dict(by_syscall.most_common(20)),
        "mainThreadShowDocumentBasenames": docs,
        "mainThreadTotalDurationMs": round(sum(r["durationNs"] for r in main_rows) / 1e6, 3),
        "mainThreadDocumentDurationMs": round(
            sum(r["durationNs"] for r in main_rows if category(r["path"]).startswith("show document")) / 1e6, 3),
    }
    print(json.dumps(summary, indent=2))
    if args.json:
        with open(args.json, "w") as handle:
            json.dump(summary, handle, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
