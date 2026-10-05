#!/usr/bin/env python3
"""M1-DUR-025 two-device iCloud trial (headless on both Macs; synthetic documents only).

Device A = this Mac, device B = the Mac mini (same iCloud account), driven over SSH. Every operation is a
`wwpersist-probe` command (WWPersistence code under test); this script only schedules, observes and judges.
No GUI, no app launches, nothing outside the trial folder and the per-run device-local state folders.

Usage:
  scripts/dur025/run.py --split calibration|holdout [--counts show=N,library=N,relink=N,recovery=N]
                        [--workers N] [--keep] [--cleanup-only]

Seeds follow docs/m1/ww-003-fixture-protocol.md:
  sha256("ww-m1-fixture|v1|M1-DUR-025|" + split + "|" + caseIndex), first 8 bytes big-endian.
Results: .build/dur025/<split>/results.jsonl (one line per case) and run-record.json (commit, trees, hosts,
clock offsets, counts, cleanup record).
"""
import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import random
import shlex
import shutil
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

FIXTURE = "M1-DUR-025"
MINI = "brandonmartinez@192.168.18.8"
HOME = str(Path.home())
TRIAL_ROOT = f"{HOME}/Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial/dur025"
REPO = Path(__file__).resolve().parents[2]
SSH_CONTROL = "/tmp/ww-dur025-%C"
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=auto", "-o", f"ControlPath={SSH_CONTROL}",
       "-o", "ControlPersist=1800", "-o", "ServerAliveInterval=15", MINI]
# m1-freeze-2 cells (registry M1-DUR-025): calibration 10 / holdout 100.
DEFAULT_COUNTS = {"calibration": {"show": 3, "library": 3, "relink": 2, "recovery": 2},
                  "holdout": {"show": 30, "library": 30, "relink": 20, "recovery": 20}}
CELL_NAMES = {"show": "show-conflict", "library": "library-conflict", "relink": "cross-machine-relink", "recovery": "recovery"}
STRATA = ["show", "library", "relink", "recovery"]
SETTLE_TIMEOUT = 420
AWAIT_TIMEOUT = 420
# Shared trigger time with a small seeded skew between the two hosts (the publications race).
RACE_SKEW_MS = [0, 0, 25, 50, 100, 250]
LIBRARY_EDITS = ["collection", "alias", "order", "recent"]
RELINK_VARIANTS = ["same", "moved", "replaced"]
RECOVERY_VARIANTS = ["bSaves", "bRelaunches", "aKilled"]


def now_ms():
    return int(time.time() * 1000)


def seed_for(split, index):
    digest = hashlib.sha256(f"ww-m1-fixture|v1|{FIXTURE}|{split}|{index}".encode()).digest()
    return int.from_bytes(digest[:8], "big")


class Devices:
    def __init__(self, sha, split):
        self.local_probe = str(REPO / ".build/swiftpm/out/Products/Debug/wwpersist-probe")
        self.remote_dir = f"{HOME}/ww-uitest-runs/dur025-{sha}"
        self.remote_probe = f"{self.remote_dir}/wwpersist-probe"
        self.local_state = REPO / f".build/dur025/{split}/state"
        self.remote_state = f"{self.remote_dir}/state/{split}"
        self.offset_ms = 0  # B clock − A clock

    def run(self, device, args, timeout=900):
        """Runs one probe command on device 'A' or 'B'; returns its JSON line (or a harness error dict)."""
        cmd = [self.local_probe] + args if device == "A" else SSH + [shlex.join([self.remote_probe] + args)]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return {"result": "harnessTimeout", "device": device, "args": args}
        lines = [l for l in out.stdout.splitlines() if l.startswith("{")]
        if not lines:
            return {"result": "noOutput", "device": device, "status": out.returncode, "stderr": out.stderr[-400:]}
        data = json.loads(lines[-1])
        data["_status"] = out.returncode
        return data

    def shell(self, device, script, timeout=120):
        cmd = ["bash", "-c", script] if device == "A" else SSH + [script]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

    def measure_offset(self, samples=9):
        best = None
        for _ in range(samples):
            t0 = time.time()
            out = subprocess.run(SSH + ["python3 -c 'import time;print(time.time())'"], capture_output=True, text=True, timeout=30)
            t1 = time.time()
            remote = float(out.stdout.strip())
            if best is None or t1 - t0 < best[0]:
                best = (t1 - t0, remote - (t0 + t1) / 2)
        self.offset_ms = int(best[1] * 1000)
        return {"offsetMs": self.offset_ms, "rttMs": round(best[0] * 1000, 1)}

    def b_time(self, a_epoch_ms):
        return a_epoch_ms + self.offset_ms

    def state(self, device, case_dir):
        return str(self.local_state / case_dir) if device == "A" else f"{self.remote_state}/{case_dir}"


def settle(dev, inspect_args, key, timeout=SETTLE_TIMEOUT, stable_polls=3, interval=4):
    """Polls both Macs until they report the same current publication and nothing changes for `stable_polls`
    consecutive polls. Returns (A report, B report, waited ms, settled)."""
    start = now_ms()
    last, same = None, 0
    a = b = {}
    while now_ms() - start < timeout * 1000:
        a = dev.run("A", inspect_args)
        b = dev.run("B", inspect_args)
        sig = (key(a), key(b))
        if sig[0] is not None and sig[0] == sig[1] and sig == last:
            same += 1
            if same >= stable_polls:
                return a, b, now_ms() - start, True
        else:
            same = 0
        last = sig
        time.sleep(interval)
    return a, b, now_ms() - start, False


def show_key(report):
    cur = report.get("current", {})
    if cur.get("outcome") != "editable":
        return None
    return (cur.get("publicationID"), len(report.get("unresolvedConflictVersions", [])), len(report.get("siblings", [])))


def lib_key(report):
    cur = report.get("current", {})
    if cur.get("outcome") != "valid":
        return None
    return (cur.get("publicationID"), len(report.get("unresolvedConflictVersions", [])), len(report.get("siblings", [])))


def await_pub(dev, device, path, publication, timeout=AWAIT_TIMEOUT):
    return dev.run(device, ["await", "--file", path, "--publication", publication, "--timeout", str(timeout)], timeout=timeout + 60)


def propagation_ms(dev, a_epoch_ms, observed_on_b):
    """A→B propagation in A's clock (an upper bound: the observer polls)."""
    if observed_on_b.get("result") != "observed":
        return None
    return observed_on_b["observedEpochMs"] - dev.offset_ms - a_epoch_ms


def b_to_a_ms(dev, b_epoch_ms, observed_on_a):
    if observed_on_a.get("result") != "observed":
        return None
    return observed_on_a["observedEpochMs"] - (b_epoch_ms - dev.offset_ms)


def race_times(rng):
    skew = rng.choice(RACE_SKEW_MS)
    first = rng.choice(["A", "B"])
    t0 = now_ms() + 6000
    ta, tb = (t0, t0 + skew) if first == "A" else (t0 + skew, t0)
    return skew, first, t0, ta, tb


def settle_tracking(dev, inspect_args, key, count_of, t0, timeout=SETTLE_TIMEOUT, stable_polls=3, interval=3):
    """Like `settle`, also recording on each host the first poll (ms after the trigger) at which `count_of(report)`
    became nonzero: the time to surfacing."""
    start = now_ms()
    last, same = None, 0
    first_seen = {"A": None, "B": None}
    a = b = {}
    while now_ms() - start < timeout * 1000:
        a = dev.run("A", inspect_args)
        b = dev.run("B", inspect_args)
        for host, report in (("A", a), ("B", b)):
            if first_seen[host] is None and count_of(report) > 0:
                first_seen[host] = now_ms() - t0
        sig = (key(a), key(b))
        if sig[0] is not None and sig[0] == sig[1] and sig == last:
            same += 1
            if same >= stable_polls:
                return a, b, now_ms() - t0, True, first_seen
        else:
            same = 0
        last = sig
        time.sleep(interval)
    return a, b, now_ms() - t0, False, first_seen


def version_counts(a, b):
    return {"A": {"unresolvedConflict": len(a.get("unresolvedConflictVersions", [])), "status": a.get("statusProviderConflicts"),
                  "other": a.get("otherVersions")},
            "B": {"unresolvedConflict": len(b.get("unresolvedConflictVersions", [])), "status": b.get("statusProviderConflicts"),
                  "other": b.get("otherVersions")}}


# ---------------------------------------------------------------- show-conflict

def case_show(dev, split, index, rng):
    """Both hosts hold revision r (synced, verified); each publishes a different seeded edit at a shared trigger
    time; judged at the settle point under protocol §4.2.1."""
    folder = f"{TRIAL_ROOT}/{split}/show/case-{index}"
    path = f"{folder}/Show.wwshow"
    os.makedirs(folder, exist_ok=True)
    ra, rb = dev.state("A", f"show-{index}") + "/recovery", dev.state("B", f"show-{index}") + "/recovery"
    created = dev.run("A", ["create", "--file", path, "--seed", str(rng.randrange(1, 10**6)), "--recovery", ra])
    t_create = now_ms()
    if created.get("result") != "saved":
        return {"verdict": "harnessError", "step": "create", "detail": created}
    seen = await_pub(dev, "B", path, created["publicationID"])
    if seen.get("result") != "observed":
        return {"verdict": "fail", "reason": "setup did not sync within the bound", "step": "awaitB", "detail": seen}
    skew, first, t0, ta, tb = race_times(rng)
    title = {"A": f"A edit {rng.randrange(10**6)} case-{index}", "B": f"B edit {rng.randrange(10**6)} case-{index}"}
    with cf.ThreadPoolExecutor(2) as pool:
        fa = pool.submit(dev.run, "A", ["save", "--file", path, "--title", title["A"], "--recovery", ra, "--at-epoch-ms", str(ta)])
        fb = pool.submit(dev.run, "B", ["save", "--file", path, "--title", title["B"], "--recovery", rb, "--at-epoch-ms", str(dev.b_time(tb))])
        saves = {"A": fa.result(), "B": fb.result()}
    a, b, settle_ms, settled, surfaced = settle_tracking(
        dev, ["inspect", "--file", path], show_key, lambda r: int(r.get("statusProviderConflicts") or 0), t0)
    reports = {"A": a, "B": b}
    acked = [h for h in ("A", "B") if saves[h].get("result") == "saved"]
    cur = {h: reports[h].get("current", {}) for h in ("A", "B")}
    # (1) one current publication, byte-identical and valid on both hosts
    one_current = (settled and all(cur[h].get("outcome") == "editable" for h in cur)
                   and reports["A"].get("sha256") and reports["A"].get("sha256") == reports["B"].get("sha256"))
    winner = next((h for h in ("A", "B") if cur["A"].get("publicationID") == saves[h].get("publicationID")), None)
    # (2) every other local ack: app-detected (conflict + candidate) or provider-surfaced (nonzero status count)
    paths, ok2 = {}, True
    for host in ("A", "B"):
        result = saves[host]
        if host == winner:
            paths[host] = "current"
            continue
        if result.get("result") == "conflict":
            candidate = dev.run(host, ["open", "--file", result.get("preservedCandidate", "-")]) if result.get("preservedCandidate") else {}
            paths[host] = "appDetected" if candidate.get("title") == title[host] else "appDetectedCandidateMissing"
            ok2 &= paths[host] == "appDetected"
        elif result.get("result") == "saved":
            in_version = any(v.get("title") == title[host] for r in reports.values() for v in r.get("unresolvedConflictVersions", []))
            # (3) the losing host must show the conflict indication itself after settle
            surfaced_on_loser = int(reports[host].get("statusProviderConflicts") or 0) > 0
            paths[host] = "providerSurfaced" if in_version and surfaced_on_loser else "silentLastWriterWins" if not in_version else "providerVersionNotSurfacedOnLoser"
            ok2 &= paths[host] == "providerSurfaced"
        else:
            paths[host] = f"noLocalAck:{result.get('result')}"
            ok2 = False
    lost = [h for h in ("A", "B") if paths.get(h) not in ("current", "appDetected", "providerSurfaced")]
    ok = bool(one_current) and winner is not None and ok2 and not lost
    return {"verdict": "pass" if ok else "fail", "skewMs": skew, "first": first,
            "localAcks": acked, "saveResults": {h: saves[h].get("result") for h in saves},
            "detectionPath": paths, "winner": winner, "oneCurrentByteIdentical": bool(one_current),
            "settled": settled, "timeToSettleMs": settle_ms, "timeToSurfacingMs": surfaced,
            "versionCounts": version_counts(a, b),
            "conflictVersionComputers": sorted({v.get("savingComputer", "") for r in reports.values() for v in r.get("unresolvedConflictVersions", [])}),
            "siblings": {h: [s.get("name") for s in reports[h].get("siblings", [])] for h in reports},
            "propagationAtoBMs": propagation_ms(dev, t_create, seen)}


# ---------------------------------------------------------------- library-conflict

def lib_args(dev, device, index, extra):
    base = dev.state(device, f"library-{index}")
    return ["lib", "--file", f"{base}/settings.json", "--container", f"{base}/container", "--recovery", f"{base}/recovery",
            "--cache", f"{base}/index.json"] + extra


def poll_lib(dev, device, libfile, predicate, timeout=AWAIT_TIMEOUT):
    start = now_ms()
    while now_ms() - start < timeout * 1000:
        report = dev.run(device, ["lib-inspect", "--file", libfile])
        if predicate(report):
            return {"result": "observed", "observedEpochMs": report["epochMs"], "report": report}
        time.sleep(1)
    return {"result": "timeout"}


def library_edit(host, kind, index, setup):
    """Each host's seeded organizing edit targets different items (so both changes can coexist)."""
    if kind == "collection":
        return ["--edit", "collection", "--edit-arg", f"{host} collection {index}"], {"kind": kind, "name": f"{host} collection {index}"}
    if kind == "alias":
        entry = 0 if host == "A" else 3
        alias = f"{host} alias {index}"
        return ["--edit", "alias", "--edit-arg", f"{entry}:{alias}"], {"kind": kind, "showID": setup["entries"][entry]["showID"], "alias": alias}
    if kind == "order":
        name = "Alpha" if host == "A" else "Beta"
        members = next(c["showIDs"] for c in setup["collections"] if c["name"] == name)
        return ["--edit", "order", "--edit-arg", name], {"kind": kind, "name": name, "showIDs": list(reversed(members))}
    entry = 2 if host == "A" else 3
    return ["--edit", "recent", "--edit-arg", str(entry)], {"kind": kind, "showID": setup["entries"][entry]["showID"]}


def edit_presence(model, edit):
    """'current' if the edit is in the current library as made, 'copy' if present only as an ST-36 suffixed copy
    (frozen Combine semantics), else None."""
    if edit["kind"] == "collection":
        names = [c["name"] for c in model.get("collections", [])]
        if edit["name"] in names:
            return "current"
        return "copy" if any(n.startswith(edit["name"] + " (") for n in names) else None
    if edit["kind"] == "alias":
        return "current" if any(e["showID"] == edit["showID"] and e["alias"] == edit["alias"] for e in model.get("entries", [])) else None
    if edit["kind"] == "order":
        for c in model.get("collections", []):
            if c["showIDs"] == edit["showIDs"]:
                return "current" if c["name"] == edit["name"] else "copy" if c["name"].startswith(edit["name"] + " (") else None
        return None
    return "current" if edit["showID"] in model.get("recents", []) else None


def case_library(dev, split, index, rng):
    """Both hosts use one synthetic library in the trial folder (same libraryID, synced and verified); each makes
    a different seeded organizing edit at a shared trigger time. §4.2.1 + truth 2: L4 → Combine on both hosts."""
    folder = f"{TRIAL_ROOT}/{split}/library/case-{index}"
    libfile = f"{folder}/Library.wwlibrary"
    os.makedirs(folder, exist_ok=True)
    moved = dev.run("A", lib_args(dev, "A", index, ["--seed-fixture", "1", "--move-to", folder]))
    t_move = now_ms()
    setup_report = dev.run("A", ["lib-inspect", "--file", libfile])
    pub = setup_report.get("current", {}).get("publicationID")
    if not pub:
        return {"verdict": "harnessError", "step": "setupA", "detail": moved}
    setup = setup_report["current"]["model"]
    seen = poll_lib(dev, "B", libfile, lambda r: r.get("current", {}).get("publicationID") == pub)
    if seen.get("result") != "observed":
        return {"verdict": "fail", "reason": "setup did not sync within the bound", "step": "awaitB"}
    used = dev.run("B", lib_args(dev, "B", index, ["--use", folder]))
    pub_b = dev.run("B", ["lib-inspect", "--file", libfile]).get("current", {}).get("publicationID")
    if pub_b != pub:
        seen_a = poll_lib(dev, "A", libfile, lambda r: r.get("current", {}).get("publicationID") == pub_b)
        if seen_a.get("result") != "observed":
            return {"verdict": "fail", "reason": "setup did not sync within the bound", "step": "awaitA", "use": used.get("use")}
    kinds = {"A": rng.choice(LIBRARY_EDITS), "B": rng.choice(LIBRARY_EDITS)}
    args_a, edit_a = library_edit("A", kinds["A"], index, setup)
    args_b, edit_b = library_edit("B", kinds["B"], index, setup)
    edits = {"A": edit_a, "B": edit_b}
    skew, first, t0, ta, tb = race_times(rng)
    with cf.ThreadPoolExecutor(2) as pool:
        fa = pool.submit(dev.run, "A", lib_args(dev, "A", index, args_a + ["--at-epoch-ms", str(ta)]))
        fb = pool.submit(dev.run, "B", lib_args(dev, "B", index, args_b + ["--at-epoch-ms", str(dev.b_time(tb))]))
        updates = {"A": fa.result(), "B": fb.result()}
    a, b, settle_ms, settled, surfaced_versions = settle_tracking(
        dev, ["lib-inspect", "--file", libfile], lib_key, lambda r: len(r.get("unresolvedConflictVersions", [])), t0)
    versions_seen = version_counts_lib(a, b)
    # Each host opens the library in turn (as the user would); a host in L4 resolves it with Combine.
    # Truth 4 / §4.2.1(4), observed directly: a host that holds unresolved conflict versions when it opens the
    # library must open in L4, or have every one of them resolved (backed up) or reported as unusable.
    combine, timings, truth4 = {}, {}, {}
    for host in ("A", "B"):
        before = dev.run(host, ["lib-inspect", "--file", libfile])
        held = len(before.get("unresolvedConflictVersions", []))
        combine[host] = dev.run(host, lib_args(dev, host, index, ["--combine", "1"]))
        timings[host] = now_ms() - t0
        after = dev.run(host, ["lib-inspect", "--file", libfile])
        in_l4 = combine[host].get("levelAfterLoad") == "changedElsewhere"
        accounted = len(after.get("unresolvedConflictVersions", [])) <= int(combine[host].get("unusableProviderConflicts") or 0)
        truth4[host] = {"heldOnOpen": held, "openedInL4": in_l4, "ok": held == 0 or in_l4 or accounted}
        settle_tracking(dev, ["lib-inspect", "--file", libfile], lib_key, lambda r: 0, t0)
    finals = {h: dev.run(h, lib_args(dev, h, index, [])) for h in ("A", "B")}
    a3, b3, final_ms, settled3, _ = settle_tracking(dev, ["lib-inspect", "--file", libfile], lib_key, lambda r: 0, t0)
    cur = {"A": a3.get("current", {}), "B": b3.get("current", {})}
    one_current = settled3 and all(c.get("outcome") == "valid" for c in cur.values()) and cur["A"].get("sha256") == cur["B"].get("sha256")
    presence = {h: {host: edit_presence(cur[host].get("model", {}), edits[h]) for host in ("A", "B")} for h in ("A", "B")}
    both_present_on_both = all(all(p in ("current", "copy") for p in presence[h].values()) for h in presence)
    app_detected = {h: str(updates[h].get("update", "")).startswith("failed") for h in ("A", "B")}
    l4_seen = {h: combine[h].get("levelAfterLoad") == "changedElsewhere" for h in ("A", "B")}
    provider_versions = any(r.get("unresolvedConflictVersions") for r in (a, b))
    truth4_ok = all(t["ok"] for t in truth4.values())
    backups = {h: combine[h].get("conflictBackups", 0) for h in ("A", "B")}
    resolved_left = sum(len(r.get("unresolvedConflictVersions", [])) for r in (a3, b3))
    finals_ready = all(finals[h].get("levelState") == "ready" for h in finals)
    acked = [h for h in ("A", "B") if str(updates[h].get("update", "")).startswith("published")]
    conflict_happened = provider_versions or any(app_detected.values()) or len(acked) > 1
    detected = any(l4_seen.values()) or any(app_detected.values())
    ok = (one_current and both_present_on_both and finals_ready and resolved_left == 0 and truth4_ok
          and (not conflict_happened or detected)
          and (not provider_versions or sum(backups.values()) > 0))
    path = ("appDetected" if any(app_detected.values()) else "providerL4" if any(l4_seen.values()) else
            "noConflictObserved" if not conflict_happened else "undetected")
    return {"verdict": "pass" if ok else "fail", "skewMs": skew, "first": first, "edits": {h: edits[h]["kind"] for h in edits},
            "localAcks": acked, "updateResults": {h: updates[h].get("update") for h in updates}, "detectionPath": path,
            "l4OnLoad": l4_seen, "truth4": truth4, "combine": {h: combine[h].get("combine", "-") for h in combine},
            "conflictBackups": backups, "presence": presence, "bothChangesOnBothHosts": both_present_on_both,
            "oneCurrentByteIdentical": bool(one_current), "unresolvedLeft": resolved_left, "finalLevels": {h: finals[h].get("levelState") for h in finals},
            "unusableProviderConflicts": {h: finals[h].get("unusableProviderConflicts") for h in finals},
            "settled": settled and settled3, "timeToSettleMs": settle_ms, "timeToSurfacingMs": {
                "providerVersionObserved": surfaced_versions, "l4OnLoadAt": {h: timings[h] if l4_seen[h] else None for h in timings}},
            "versionCounts": versions_seen, "finalSettleMs": final_ms,
            "conflictVersionComputers": sorted({v.get("savingComputer", "") for r in (a, b) for v in r.get("unresolvedConflictVersions", [])}),
            "propagationAtoBMs": propagation_ms(dev, t_move, seen)}


def version_counts_lib(a, b):
    return {h: {"unresolvedConflict": len(r.get("unresolvedConflictVersions", [])), "other": r.get("otherVersions")} for h, r in (("A", a), ("B", b))}


# ---------------------------------------------------------------- cross-machine-relink

def case_relink(dev, split, index, rng):
    """Sources (random-byte files) with device access records on A only. B opens with no record (never by path or
    name), then gets the location as an explicit choice. Variants: same files; a source moved; a source
    replaced by a same-name different file (both before B opens). Zero source writes on both hosts."""
    variant = RELINK_VARIANTS[index % len(RELINK_VARIANTS)]
    folder = f"{TRIAL_ROOT}/{split}/relink/case-{index}"
    sources = f"{folder}/sources"
    records_a, records_b = dev.state("A", f"relink-{index}") + "/records", dev.state("B", f"relink-{index}") + "/records"
    made = dev.run("A", ["src-make", "--file", sources, "--count", "3", "--seed", str(rng.randrange(1, 2**40))])
    if made.get("result") != "made":
        return {"verdict": "harnessError", "step": "src-make", "detail": made}
    show_path = f"{folder}/Show.wwshow"
    dev.run("A", ["create", "--file", show_path, "--seed", str(rng.randrange(1, 10**6))])
    show_id = read_show_id(show_path)
    source_ids = [str(uuid.UUID(int=rng.getrandbits(128))) for _ in made["files"]]
    expected = {f["path"]: f["sha256"] for f in made["files"]}
    for sid, f in zip(source_ids, made["files"]):
        dev.run("A", ["src-record", "--file", records_a, "--show", show_id, "--source", sid, "--source-file", f["path"]])
    # B sees the show and the sources.
    for f in made["files"]:
        if not await_digest(dev, "B", f["path"], f["sha256"]):
            return {"verdict": "fail", "reason": "setup did not sync within the bound", "step": f"awaitB {f['path']}"}
    target = made["files"][1]["path"]
    supplied = target
    if variant == "moved":
        os.makedirs(f"{folder}/moved", exist_ok=True)
        supplied = f"{folder}/moved/{os.path.basename(target)}"
        os.replace(target, supplied)
        expected[supplied] = expected.pop(target)
        if not await_digest(dev, "B", supplied, expected[supplied]) or not await_absent(dev, "B", target):
            return {"verdict": "fail", "reason": "move did not sync within the bound", "step": "awaitB moved"}
    elif variant == "replaced":
        replacement = dev.run("A", ["src-make", "--file", f"{folder}/.replacement", "--count", "1", "--seed", str(rng.randrange(1, 2**40))])
        os.replace(replacement["files"][0]["path"], target)
        expected[target] = replacement["files"][0]["sha256"]
        if not await_digest(dev, "B", target, expected[target]):
            return {"verdict": "fail", "reason": "replacement did not sync within the bound", "step": "awaitB replaced"}
    # B, with no access record: never resolved by path or name.
    b_eval = [dev.run("B", ["src-eval", "--file", records_b, "--show", show_id, "--source", sid]) for sid in source_ids]
    never_by_path = all(e.get("hasRecord") is False and e.get("access") == "needsRegrant" and not e.get("resolvedPath") for e in b_eval)
    # Explicit choice: without the user's confirmation nothing is applied; with it, B records its own baseline.
    sid = source_ids[1]
    unconfirmed = dev.run("B", ["src-relink", "--file", records_b, "--show", show_id, "--source", sid, "--source-file", supplied, "--confirm", "0"])
    confirmed = dev.run("B", ["src-relink", "--file", records_b, "--show", show_id, "--source", sid, "--source-file", supplied, "--confirm", "1"])
    b_after = dev.run("B", ["src-eval", "--file", records_b, "--show", show_id, "--source", sid])
    # A (which holds the evidence) reports the moved / replaced source as different, never substituted.
    a_eval = dev.run("A", ["src-eval", "--file", records_a, "--show", show_id, "--source", sid])
    if variant == "same":
        # Untouched source: present and matching A's recorded baseline exactly. (Calibration-1/2's date-only
        # "changed" was the probe's own record encoding truncating dates to whole seconds — fixed by using the
        # app's FileDeviceAccessStore — not iCloud; see the evidence document.)
        a_ok = a_eval.get("location") == "present" and a_eval.get("identity") == "matchesRecorded"
    elif variant == "moved":
        a_ok = a_eval.get("location", "").startswith("moved") or a_eval.get("location", "").startswith("missing")
    else:
        a_ok = a_eval.get("identity", "").startswith(("mismatch", "changed")) or a_eval.get("access") in ("staleBookmark", "needsRegrant")
    # #121 data: raw dates of the relinked source — A's recorded baseline (its access record) and what each
    # host's file system reports now (UTC, ms), so any drift is measured rather than inferred.
    stat_script = ("import os,sys,json,datetime as d; s=os.stat(sys.argv[1]); f=lambda t: d.datetime.fromtimestamp(t,d.timezone.utc).isoformat(timespec='milliseconds');"
                   "print(json.dumps({'creation': f(s.st_birthtime), 'modification': f(s.st_mtime_ns/1e9), 'inode': s.st_ino}))")
    dates = {}
    for host in ("A", "B"):
        out = dev.shell(host, f"python3 -c {shlex.quote(stat_script)} {shlex.quote(supplied)}")
        try:
            dates[host] = json.loads(out.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            dates[host] = {"error": out.stderr[-200:]}
    try:
        with open(f"{records_a}/{sid.upper()}.json") as handle:
            dates["A recorded baseline"] = json.load(handle).get("recordedIdentity", {}).get("fingerprint")
    except OSError as error:
        dates["A recorded baseline"] = {"error": str(error)}
    # Zero source writes: every source digest on both hosts is exactly what A generated.
    digests = {h: {p: dev.run(h, ["digest", "--file", p]).get("sha256") for p in expected} for h in ("A", "B")}
    zero_writes = all(digests[h][p] == expected[p] for h in digests for p in expected)
    ok = (never_by_path and str(unconfirmed.get("result", "")).startswith("confirmationRequired")
          and confirmed.get("result") == "applied" and b_after.get("access") == "granted" and a_ok and zero_writes)
    return {"verdict": "pass" if ok else "fail", "variant": variant, "bWithoutRecord": [{k: e.get(k) for k in ("access", "location", "identity")} for e in b_eval],
            "neverResolvedByPathOrName": never_by_path, "bUnconfirmed": unconfirmed.get("result"), "bUnconfirmedComparison": unconfirmed.get("comparison"),
            "bConfirmed": confirmed.get("result"), "bAfterRegrant": {k: b_after.get(k) for k in ("access", "identity")},
            "aReportsChangedSource": {k: a_eval.get(k) for k in ("location", "identity", "access")}, "aCorrect": a_ok,
            "aUntouchedSourceDatesChangedBySync": variant == "same" and a_eval.get("identity", "").startswith("changed("),
            "sourceDates": dates,
            "zeroSourceWrites": zero_writes, "sourceFiles": len(expected)}


def await_digest(dev, host, path, sha, timeout=AWAIT_TIMEOUT):
    start = now_ms()
    while now_ms() - start < timeout * 1000:
        dev.run(host, ["await", "--file", path, "--exists", "1", "--timeout", "5"], timeout=60)
        if dev.run(host, ["digest", "--file", path]).get("sha256") == sha:
            return True
        time.sleep(1)
    return False


def await_absent(dev, host, path, timeout=AWAIT_TIMEOUT):
    return dev.run(host, ["await", "--file", path, "--exists", "0", "--timeout", str(timeout)], timeout=timeout + 60).get("result") == "observed"


def read_show_id(path):
    with open(path, "rb") as handle:
        return json.load(handle)["payload"]["show"]["id"]


# ---------------------------------------------------------------- recovery

def case_recovery(dev, split, index, rng):
    """A publishes r+1 while B holds unpublished edits on r (C2b checkpoint on B). Variants: B then saves (base
    check); B quits and relaunches before saving; A is killed at P4 or P5 while B is idle. Truth 6: unpublished
    work stays recoverable on its host; nothing is reported Saved that wasn't read back on that host."""
    variant = RECOVERY_VARIANTS[index % len(RECOVERY_VARIANTS)]
    folder = f"{TRIAL_ROOT}/{split}/recovery/case-{index}"
    path = f"{folder}/Show.wwshow"
    os.makedirs(folder, exist_ok=True)
    ra, rb = dev.state("A", f"recovery-{index}") + "/recovery", dev.state("B", f"recovery-{index}") + "/recovery"
    created = dev.run("A", ["create", "--file", path, "--seed", str(rng.randrange(1, 10**6)), "--recovery", ra])
    seen = await_pub(dev, "B", path, created.get("publicationID", "-"))
    if seen.get("result") != "observed":
        return {"verdict": "fail", "reason": "setup did not sync within the bound", "step": "awaitB"}
    b_title, a_title = f"B unpublished case-{index}", f"A r2 case-{index}"
    if variant == "bSaves":
        ready, go = dev.state("B", f"recovery-{index}") + "/ready", dev.state("B", f"recovery-{index}") + "/go"
        dev.shell("B", f"mkdir -p {shlex.quote(os.path.dirname(ready))}")
        with cf.ThreadPoolExecutor(1) as pool:
            held = pool.submit(dev.run, "B", ["hold-save", "--file", path, "--title", b_title, "--recovery", rb, "--ready", ready, "--go", go])
            while dev.shell("B", f"test -f {shlex.quote(ready)}").returncode != 0:
                time.sleep(0.5)
            a2 = dev.run("A", ["save", "--file", path, "--title", a_title, "--recovery", ra])
            arrived = await_pub(dev, "B", path, a2.get("publicationID", "-"))
            dev.shell("B", f"touch {shlex.quote(go)}")
            result = held.result()
        candidate = dev.run("B", ["open", "--file", result.get("preservedCandidate", "-")]) if result.get("preservedCandidate") else {}
        a, b, settle_ms, settled = settle(dev, ["inspect", "--file", path], show_key)
        ok = (arrived.get("result") == "observed" and result.get("checkpointWritten") is True and result.get("result") == "conflict"
              and candidate.get("title") == b_title and int(result.get("editCheckpointsKept", 0)) >= 1
              and "saved" not in str(result.get("status", "")).lower()
              and settled and a.get("sha256") == b.get("sha256") and a.get("current", {}).get("title") == a_title)
        return {"verdict": "pass" if ok else "fail", "variant": variant, "bResult": result.get("result"), "bStatus": result.get("status"),
                "bCandidateTitle": candidate.get("title"), "bEditCheckpointsKept": result.get("editCheckpointsKept"),
                "currentOnBoth": a.get("current", {}).get("title"), "byteIdentical": a.get("sha256") == b.get("sha256"), "timeToSettleMs": settle_ms}
    if variant == "bRelaunches":
        quit_b = dev.run("B", ["checkpoint", "--file", path, "--title", b_title, "--recovery", rb])
        a2 = dev.run("A", ["save", "--file", path, "--title", a_title, "--recovery", ra])
        arrived = await_pub(dev, "B", path, a2.get("publicationID", "-"))
        offer = dev.run("B", ["offer", "--file", path, "--recovery", rb])
        a, b, settle_ms, settled = settle(dev, ["inspect", "--file", path], show_key)
        ok = (quit_b.get("result") == "checkpointed" and "saved" not in str(quit_b.get("status", "")).lower()
              and arrived.get("result") == "observed" and offer.get("candidateTitle") == b_title
              and offer.get("mode") == "copyOnlyOlderRevision" and offer.get("currentTitle") == a_title
              and settled and a.get("sha256") == b.get("sha256"))
        return {"verdict": "pass" if ok else "fail", "variant": variant, "bQuitStatus": quit_b.get("status"),
                "bOfferOnRelaunch": {k: offer.get(k) for k in ("candidateTitle", "relation", "mode", "currentTitle")},
                "byteIdentical": a.get("sha256") == b.get("sha256"), "timeToSettleMs": settle_ms}
    boundary = rng.choice(["P4", "P5"])
    a2 = dev.run("A", ["save", "--file", path, "--title", a_title, "--recovery", ra])
    arrived = await_pub(dev, "B", path, a2.get("publicationID", "-"))
    marker = dev.state("A", f"recovery-{index}") + "/marker"
    os.makedirs(os.path.dirname(marker), exist_ok=True)
    killed = dev.run("A", ["kill-at", "--file", path, "--boundary", boundary, "--recovery", ra, "--marker", marker])
    marker_ok = os.path.exists(marker) and open(marker).read() == boundary
    expected = a_title if boundary == "P4" else f"Killed at {boundary}"
    a, b, settle_ms, settled = settle(dev, ["inspect", "--file", path], show_key)
    titles = {r.get("current", {}).get("title") for r in (a, b)}
    reopened_b = dev.run("B", ["open", "--file", path, "--recovery", rb])
    ok = (arrived.get("result") == "observed" and marker_ok and killed.get("result") != "saved" and settled
          and a.get("sha256") == b.get("sha256") and titles == {expected} and reopened_b.get("outcome") == "editable")
    return {"verdict": "pass" if ok else "fail", "variant": f"aKilled{boundary}", "killedAtBoundary": marker_ok,
            "aReportedSaved": killed.get("result") == "saved", "currentOnBoth": sorted(t or "" for t in titles), "expected": expected,
            "byteIdentical": a.get("sha256") == b.get("sha256"), "timeToSettleMs": settle_ms}


CASES = {"show": case_show, "library": case_library, "relink": case_relink, "recovery": case_recovery}


def run_case(dev, stratum, split, index, rng):
    started = now_ms()
    try:
        result = CASES[stratum](dev, split, index, rng)
    except Exception as error:  # a harness defect is recorded, never hidden
        result = {"verdict": "harnessError", "exception": repr(error)}
    result.update({"stratum": stratum, "caseIndex": index, "seed": seed_for(split, index), "durationMs": now_ms() - started})
    return result


def git(*args):
    return subprocess.run(["git", "-C", str(REPO)] + list(args), capture_output=True, text=True).stdout.strip()


def host_record(dev, device):
    script = "hostname; sw_vers -productVersion; sw_vers -buildVersion; sysctl -n machdep.cpu.brand_string; sysctl -n hw.ncpu"
    out = dev.shell(device, script).stdout.split("\n")
    return {"hostname": out[0], "macOS": f"{out[1]} ({out[2]})", "cpu": out[3], "cores": out[4]}


def cleanup(dev, split=None):
    """Deletes the trial (sub)folder (iCloud propagates the deletion to the mini) and both Macs' device-local state."""
    target = f"{TRIAL_ROOT}/{split}" if split else TRIAL_ROOT
    existed = os.path.exists(target)
    shutil.rmtree(target, ignore_errors=True)
    shutil.rmtree(dev.local_state, ignore_errors=True)
    subprocess.run(SSH + [f"rm -rf {shlex.quote(dev.remote_state)}"])
    return {"deleted": target, "existedBefore": existed, "existsAfterLocally": os.path.exists(target),
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--split", choices=["calibration", "holdout"], default="calibration")
    parser.add_argument("--counts", default="")
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--keep", action="store_true", help="don't delete the trial folder afterwards")
    parser.add_argument("--cleanup-only", action="store_true")
    args = parser.parse_args()
    sha = git("rev-parse", "--short", "HEAD")
    dev = Devices(sha, args.split)
    if args.cleanup_only:
        print(json.dumps(cleanup(dev)))
        return
    counts = dict(DEFAULT_COUNTS[args.split])
    for part in filter(None, args.counts.split(",")):
        key, value = part.split("=")
        counts[key] = int(value)
    if args.split == "holdout":
        if git("status", "--porcelain"):
            sys.exit("holdout requires a clean tree")
        # m1-freeze-2 (ad9af5a), the §4.2.1 interpretation (ce1eb23) and the #118 merge, given by the coordinator.
        required = [c for c in os.environ.get("WW_REQUIRED_COMMITS", "").split(",") if c]
        if len(required) < 3:
            sys.exit("holdout requires WW_REQUIRED_COMMITS=<freeze-2>,<§4.2.1>,<#118 merge>")
        for commit in required:
            if subprocess.run(["git", "-C", str(REPO), "merge-base", "--is-ancestor", commit, "HEAD"]).returncode != 0:
                sys.exit(f"holdout requires {commit} to be an ancestor of HEAD")
    out_dir = REPO / f".build/dur025/{args.split}"
    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(dev.local_state, ignore_errors=True)
    subprocess.run(SSH + [f"mkdir -p {shlex.quote(dev.remote_dir)} && rm -rf {shlex.quote(dev.remote_state)}"], check=True)
    subprocess.run(["rsync", "-a", "-e", f"ssh -o ControlPath={SSH_CONTROL}", dev.local_probe, f"{MINI}:{dev.remote_dir}/"], check=True)
    local_sum = hashlib.sha256(open(dev.local_probe, "rb").read()).hexdigest()
    remote_sum = subprocess.run(SSH + [f"shasum -a 256 {shlex.quote(dev.remote_probe)}"], capture_output=True, text=True).stdout.split()[0]
    if local_sum != remote_sum:
        sys.exit("the probe on the mini differs from this Mac's build")
    record = {"fixture": FIXTURE, "split": args.split, "commit": git("rev-parse", "HEAD"), "probeSha256": local_sum,
              "freeze": "m1-freeze-2", "interpretation": "ww-003-fixture-protocol.md §4.2.1",
              "requiredCommits": os.environ.get("WW_REQUIRED_COMMITS", ""), "cells": CELL_NAMES,
              "label": "two-host evidence: Mac (host A) + Mac mini 'Macsimus' (host B), same Apple account, iCloud Drive",
              "hosts": {"A": host_record(dev, "A"), "B": host_record(dev, "B")}, "clockOffsetStart": dev.measure_offset(),
              "counts": counts, "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "trialRoot": TRIAL_ROOT,
              "trees": {p: git("rev-parse", f"HEAD:{p}") for p in ["Packages/WaveWranglerKit/Sources/WWPersistence",
                                                                   "Packages/WaveWranglerKit/Sources/WWPersistenceProbe", "scripts/dur025"]}}
    plan, index = [], 0
    for stratum in STRATA:
        for _ in range(counts.get(stratum, 0)):
            plan.append((stratum, index))
            index += 1
    results_path = out_dir / "results.jsonl"
    with open(results_path, "w") as results, cf.ThreadPoolExecutor(args.workers) as pool:
        futures = {pool.submit(run_case, dev, s, args.split, i, random.Random(seed_for(args.split, i))): (s, i) for s, i in plan}
        for future in cf.as_completed(futures):
            stratum, i = futures[future]
            line = future.result()
            results.write(json.dumps(line, sort_keys=True) + "\n")
            results.flush()
            print(f"[{stratum} {i}] {line['verdict']} {line.get('mechanism', line.get('variant', ''))}", flush=True)
    record["clockOffsetEnd"] = dev.measure_offset()
    record["finishedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if not args.keep:
        record["cleanup"] = cleanup(dev, split=args.split)
    (out_dir / "run-record.json").write_text(json.dumps(record, indent=2, sort_keys=True))
    print(json.dumps({"results": str(results_path), "record": str(out_dir / "run-record.json")}))


if __name__ == "__main__":
    main()
