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
from pathlib import Path

FIXTURE = "M1-DUR-025"
MINI = "brandonmartinez@192.168.18.8"
HOME = str(Path.home())
TRIAL_ROOT = f"{HOME}/Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial/dur025"
REPO = Path(__file__).resolve().parents[2]
SSH_CONTROL = "/tmp/ww-dur025-%C"
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=auto", "-o", f"ControlPath={SSH_CONTROL}",
       "-o", "ControlPersist=1800", "-o", "ServerAliveInterval=15", MINI]
DEFAULT_COUNTS = {"calibration": {"show": 3, "library": 3, "relink": 2, "recovery": 2},
                  "holdout": {"show": 25, "library": 25, "relink": 25, "recovery": 25}}
STRATA = ["show", "library", "relink", "recovery"]
SETTLE_TIMEOUT = 300
AWAIT_TIMEOUT = 300
RACE_DELTAS_MS = [0, 0, 250, 1000, 3000, 10000, 30000, 60000]
RELINK_VARIANTS = ["noRecordThenRegrant", "copiedRecord", "impostor", "moved"]
RECOVERY_VARIANTS = ["killP3", "killP4", "killP5", "killP6", "damagedPropagated"]


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
    delta = rng.choice(RACE_DELTAS_MS)
    first = rng.choice(["A", "B"])
    t0 = now_ms() + 6000
    ta, tb = (t0, t0 + delta) if first == "A" else (t0 + delta, t0)
    return delta, first, ta, tb


# ---------------------------------------------------------------- strata

def case_show(dev, split, index, rng):
    """Show conflict: both Macs hold revision 1 and save a different edit inside a controlled race window."""
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
        return {"verdict": "harnessError", "step": "awaitB", "detail": seen}
    prop = propagation_ms(dev, t_create, seen)
    delta, first, ta, tb = race_times(rng)
    title_a, title_b = f"A edit case-{index}", f"B edit case-{index}"
    with cf.ThreadPoolExecutor(2) as pool:
        fa = pool.submit(dev.run, "A", ["save", "--file", path, "--title", title_a, "--recovery", ra, "--at-epoch-ms", str(ta)])
        fb = pool.submit(dev.run, "B", ["save", "--file", path, "--title", title_b, "--recovery", rb, "--at-epoch-ms", str(dev.b_time(tb))])
        sa, sb = fa.result(), fb.result()
    a, b, waited, settled = settle(dev, ["inspect", "--file", path], show_key)
    preserved = {title_a: [], title_b: []}
    for device, report in (("A", a), ("B", b)):
        cur = report.get("current", {})
        if cur.get("title") in preserved:
            preserved[cur["title"]].append(f"{device}:current")
        for v in report.get("unresolvedConflictVersions", []):
            if v.get("title") in preserved:
                preserved[v["title"]].append(f"{device}:providerConflictVersion")
        for s in report.get("siblings", []):
            if s.get("title") in preserved:
                preserved[s["title"]].append(f"{device}:siblingCopy")
    for device, result, title in (("A", sa, title_a), ("B", sb, title_b)):
        if result.get("result") == "conflict" and result.get("preservedCandidate"):
            cand = dev.run(device, ["open", "--file", result["preservedCandidate"]])
            if cand.get("title") == title:
                preserved[title].append(f"{device}:appConflictCandidate")
    current = [r.get("current", {}) for r in (a, b)]
    current_titles = {c.get("title") for c in current}
    whole = all(c.get("outcome") == "editable" for c in current)
    lost = [t for t, where in preserved.items() if not where]
    ok = settled and whole and not lost and len(current_titles) == 1 and current_titles <= {title_a, title_b}
    saves = (sa.get("result"), sb.get("result"))
    mechanism = ("appDetected" if "conflict" in saves else
                 "providerConflictVersion" if any("providerConflictVersion" in w for ws in preserved.values() for w in ws) else
                 "siblingCopy" if any("siblingCopy" in w for ws in preserved.values() for w in ws) else "none")
    return {"verdict": "pass" if ok else "fail", "deltaMs": delta, "first": first, "saveA": saves[0], "saveB": saves[1],
            "winner": sorted(t or "" for t in current_titles), "preserved": preserved, "mechanism": mechanism,
            "currentWhole": whole, "settled": settled, "settledMs": waited, "propagationAtoBMs": prop,
            "conflictVersions": {"A": len(a.get("unresolvedConflictVersions", [])), "B": len(b.get("unresolvedConflictVersions", []))},
            "conflictVersionComputers": sorted({v.get("savingComputer", "") for r in (a, b) for v in r.get("unresolvedConflictVersions", [])}),
            "siblings": {"A": [s.get("name") for s in a.get("siblings", [])], "B": [s.get("name") for s in b.get("siblings", [])]},
            "currentSavingComputer": {"A": a.get("currentSavingComputer"), "B": b.get("currentSavingComputer")}}


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


def case_library(dev, split, index, rng):
    """Library conflict: one user-folder library used by both Macs; both add a collection inside the race window."""
    folder = f"{TRIAL_ROOT}/{split}/library/case-{index}"
    libfile = f"{folder}/Library.wwlibrary"
    os.makedirs(folder, exist_ok=True)
    moved = dev.run("A", lib_args(dev, "A", index, ["--move-to", folder]))
    t_move = now_ms()
    pub = dev.run("A", ["lib-inspect", "--file", libfile]).get("current", {}).get("publicationID")
    if not pub:
        return {"verdict": "harnessError", "step": "moveA", "detail": moved}
    seen = poll_lib(dev, "B", libfile, lambda r: r.get("current", {}).get("publicationID") == pub)
    if seen.get("result") != "observed":
        return {"verdict": "harnessError", "step": "awaitB", "detail": seen}
    prop = propagation_ms(dev, t_move, seen)
    used = dev.run("B", lib_args(dev, "B", index, ["--use", folder]))
    pub_b = dev.run("B", ["lib-inspect", "--file", libfile]).get("current", {}).get("publicationID")
    t_use_b = dev.b_time(now_ms())
    seen_a = poll_lib(dev, "A", libfile, lambda r: r.get("current", {}).get("publicationID") == pub_b)
    if seen_a.get("result") != "observed":
        return {"verdict": "harnessError", "step": "awaitA", "detail": seen_a, "use": used}
    # "Use That Library" publishes only if B's library added anything; otherwise there is nothing to propagate.
    prop_ba = b_to_a_ms(dev, t_use_b, seen_a) if pub_b != pub else None
    delta, first, ta, tb = race_times(rng)
    name_a, name_b = f"A collection {index}", f"B collection {index}"
    with cf.ThreadPoolExecutor(2) as pool:
        fa = pool.submit(dev.run, "A", lib_args(dev, "A", index, ["--add-collection", name_a, "--at-epoch-ms", str(ta)]))
        fb = pool.submit(dev.run, "B", lib_args(dev, "B", index, ["--add-collection", name_b, "--at-epoch-ms", str(dev.b_time(tb))]))
        ua, ub = fa.result(), fb.result()
    a, b, waited, _ = settle(dev, ["lib-inspect", "--file", libfile], lib_key)
    # Each Mac opens the library in turn, as a user would; one in L4 (an app-detected conflict at publication,
    # or a provider conflict version detected on load, #117) resolves it with Combine (Keep Everything).
    ca = dev.run("A", lib_args(dev, "A", index, ["--combine", "1"]))
    a1, b1, waited1, _ = settle(dev, ["lib-inspect", "--file", libfile], lib_key)
    cb = dev.run("B", lib_args(dev, "B", index, ["--combine", "1"]))
    a2, b2, waited2, settled2 = settle(dev, ["lib-inspect", "--file", libfile], lib_key)
    # A final open on both Macs: anything already included is resolved; nothing may still be in L4.
    fa = dev.run("A", lib_args(dev, "A", index, []))
    fb = dev.run("B", lib_args(dev, "B", index, []))
    a3, b3, waited3, settled3 = settle(dev, ["lib-inspect", "--file", libfile], lib_key)
    in_current = {name_a: [], name_b: []}
    elsewhere = {name_a: [], name_b: []}

    def note(target, names, where):
        for n in names:
            for want in target:
                if n == want or n.startswith(want + " "):
                    target[want].append(where)
    for device, report in (("A", a3), ("B", b3)):
        note(in_current, report.get("current", {}).get("collections", []), device)
        for v in report.get("unresolvedConflictVersions", []):
            note(elsewhere, v.get("collections", []), f"{device}:providerConflictVersion")
        for sib in report.get("siblings", []):
            note(elsewhere, sib.get("collections", []), f"{device}:siblingCopy")
    provider_seen = any(r.get("unresolvedConflictVersions") for r in (a, b))
    app_detected = any(str(u.get("update", "")).startswith("failed") for u in (ua, ub))
    detected = {"A": ca.get("levelAfterLoad") == "changedElsewhere" or str(ua.get("update", "")).startswith("failed"),
                "B": cb.get("levelAfterLoad") == "changedElsewhere" or str(ub.get("update", "")).startswith("failed")}
    backups = {"A": ca.get("conflictBackups", 0), "B": cb.get("conflictBackups", 0)}
    current = [r.get("current", {}) for r in (a3, b3)]
    valid = all(c.get("outcome") == "valid" for c in current)
    same = current[0].get("publicationID") == current[1].get("publicationID")
    both_in_current_on_both = all(sorted(set(w)) == ["A", "B"] for w in in_current.values())
    unresolved_left = sum(len(r.get("unresolvedConflictVersions", [])) for r in (a3, b3))
    final_levels = {"A": fa.get("levelState"), "B": fb.get("levelState")}
    conflict_occurred = provider_seen or app_detected
    ok = (settled3 and valid and same and both_in_current_on_both and unresolved_left == 0
          and all(level == "ready" for level in final_levels.values())
          and (not conflict_occurred or any(detected.values()))
          and (not provider_seen or any(n > 0 for n in backups.values())))
    mechanism = "appDetected" if app_detected else "providerConflictVersion" if provider_seen else "noConflict"
    return {"verdict": "pass" if ok else "fail", "deltaMs": delta, "first": first, "mechanism": mechanism,
            "updateA": ua.get("update"), "updateB": ub.get("update"),
            "detectedL4": detected, "levelAfterLoadAtCombine": {"A": ca.get("levelAfterLoad"), "B": cb.get("levelAfterLoad")},
            "combine": {"A": ca.get("combine", "-"), "B": cb.get("combine", "-")}, "conflictBackups": backups,
            "inCurrent": in_current, "onlyElsewhere": elsewhere, "bothInCurrentOnBothMacs": both_in_current_on_both,
            "finalLevels": final_levels, "unresolvedConflictVersionsLeft": unresolved_left,
            "unusableProviderConflicts": {"A": fa.get("unusableProviderConflicts"), "B": fb.get("unusableProviderConflicts")},
            "conflictVersionsSeen": {"A": len(a.get("unresolvedConflictVersions", [])), "B": len(b.get("unresolvedConflictVersions", []))},
            "conflictVersionComputers": sorted({v.get("savingComputer", "") for r in (a, b) for v in r.get("unresolvedConflictVersions", [])}),
            "settled": settled3, "settledMs": waited + waited1 + waited2 + waited3,
            "propagationAtoBMs": prop, "propagationBtoAMs": prop_ba}


def read_show_id(path):
    with open(path, "rb") as handle:
        return json.load(handle)["payload"]["show"]["id"]


def case_relink(dev, split, index, rng):
    """Device-local access records never travel and are never trusted across Macs: B needs its own explicit grant;
    a moved file, or a different show at the recorded path, is never opened or written as this show."""
    variant = RELINK_VARIANTS[index % len(RELINK_VARIANTS)]
    folder = f"{TRIAL_ROOT}/{split}/relink/case-{index}"
    path = f"{folder}/Show.wwshow"
    os.makedirs(folder, exist_ok=True)
    la, lb = dev.state("A", f"relink-{index}") + "/locations", dev.state("B", f"relink-{index}") + "/locations"
    ra, rb = dev.state("A", f"relink-{index}") + "/recovery", dev.state("B", f"relink-{index}") + "/recovery"
    dev.run("A", ["create", "--file", path, "--seed", str(rng.randrange(1, 10**6)), "--recovery", ra])
    sid = read_show_id(path)
    dev.run("A", ["record-location", "--file", la, "--show", sid, "--doc", path])
    first = dev.run("A", ["reopen-save", "--file", la, "--show", sid, "--title", f"A saved case-{index}", "--recovery", ra])
    t_a = now_ms()
    if first.get("outcome") != "opened" or first.get("result") != "saved":
        return {"verdict": "harnessError", "step": "A reopen-save", "detail": first}
    seen = await_pub(dev, "B", path, first["publicationID"])
    if seen.get("result") != "observed":
        return {"verdict": "harnessError", "step": "awaitB", "detail": seen}
    prop = propagation_ms(dev, t_a, seen)
    steps = {}
    not_opened = {"noRecord", "regrantRequired", "relinkRequired"}
    if variant in ("noRecordThenRegrant", "copiedRecord"):
        if variant == "copiedRecord":
            # A's device-local record arrives on B (e.g. a copied app container). It must not stand in for B's own grant.
            dev.shell("B", f"mkdir -p {shlex.quote(lb)}")
            subprocess.run(["rsync", "-a", "-e", f"ssh -o ControlPath={SSH_CONTROL}", f"{la}/", f"{MINI}:{lb}/"], check=True)
        before = dev.run("B", ["reopen-save", "--file", lb, "--show", sid, "--title", f"B unauthorised case-{index}", "--recovery", rb])
        steps["B before explicit grant"] = before.get("outcome")
        dev.run("B", ["record-location", "--file", lb, "--show", sid, "--doc", path])   # B's explicit grant (user's choice)
        granted = dev.run("B", ["reopen-save", "--file", lb, "--show", sid, "--title", f"B saved case-{index}", "--recovery", rb])
        steps["B after explicit grant"] = f"{granted.get('outcome')}/{granted.get('result')}"
        t_b = dev.b_time(now_ms())
        back = await_pub(dev, "A", path, granted.get("publicationID", "-")) if granted.get("result") == "saved" else {"result": "skipped"}
        again = dev.run("A", ["reopen-save", "--file", la, "--show", sid, "--title", f"A again case-{index}", "--recovery", ra])
        steps["A reopen after B's save"] = f"{again.get('outcome')}/{again.get('result')}"
        ok = (before.get("outcome") in not_opened and before.get("result") != "saved"
              and granted.get("outcome") == "opened" and granted.get("result") == "saved" and back.get("result") == "observed"
              and again.get("outcome") in ("opened", "relinkRequired", "regrantRequired"))
        return {"verdict": "pass" if ok else "fail", "variant": variant, "steps": steps, "beforeGrantReason": before.get("reason", ""),
                "propagationAtoBMs": prop, "propagationBtoAMs": b_to_a_ms(dev, t_b, back)}
    dev.run("B", ["record-location", "--file", lb, "--show", sid, "--doc", path])   # B's own explicit grant for the real show
    if variant == "impostor":
        impostor = f"{folder}/.impostor.wwshow"
        made = dev.run("A", ["create", "--file", impostor, "--seed", str(rng.randrange(10**6, 2 * 10**6))])
        os.replace(impostor, path)   # a different show now sits at the recorded path
        seen2 = await_pub(dev, "B", path, made.get("publicationID", "-"))
        attempt = dev.run("B", ["reopen-save", "--file", lb, "--show", sid, "--title", f"B wrong case-{index}", "--recovery", rb])
        steps["B reopen; path holds another show"] = attempt.get("outcome")
        time.sleep(2)
        unchanged = dev.run("B", ["open", "--file", path]).get("publicationID") == made.get("publicationID")
        ok = (seen2.get("result") == "observed" and attempt.get("outcome") in {"relinkRequired", "regrantRequired"}
              and attempt.get("result") != "saved" and unchanged)
        return {"verdict": "pass" if ok else "fail", "variant": variant, "steps": steps, "otherShowUnchanged": unchanged,
                "reason": attempt.get("reason", ""), "propagationAtoBMs": prop}
    target = f"{folder}/moved"
    os.makedirs(target, exist_ok=True)
    moved_path = f"{target}/Show.wwshow"
    os.replace(path, moved_path)
    gone = dev.run("B", ["await", "--file", path, "--exists", "0", "--timeout", str(AWAIT_TIMEOUT)], timeout=AWAIT_TIMEOUT + 60)
    arrived = await_pub(dev, "B", moved_path, first["publicationID"])
    attempt = dev.run("B", ["reopen-save", "--file", lb, "--show", sid, "--title", f"B moved case-{index}", "--recovery", rb])
    steps["B reopen after move on A"] = attempt.get("outcome")
    time.sleep(2)
    unchanged = dev.run("B", ["open", "--file", moved_path]).get("publicationID") == first["publicationID"]
    ok = (gone.get("result") == "observed" and arrived.get("result") == "observed"
          and attempt.get("outcome") in {"relinkRequired", "regrantRequired"} and attempt.get("result") != "saved" and unchanged)
    return {"verdict": "pass" if ok else "fail", "variant": variant, "steps": steps, "movedFileUnchanged": unchanged,
            "reason": attempt.get("reason", ""), "propagationAtoBMs": prop}


def case_recovery(dev, split, index, rng):
    """Interrupted or damaged publications on one Mac: the other Mac only ever sees a whole valid revision; a
    damaged current is never applied, and a whole coherent prior is offered where one was retained."""
    variant = RECOVERY_VARIANTS[index % len(RECOVERY_VARIANTS)]
    folder = f"{TRIAL_ROOT}/{split}/recovery/case-{index}"
    path = f"{folder}/Show.wwshow"
    os.makedirs(folder, exist_ok=True)
    ra, rb = dev.state("A", f"recovery-{index}") + "/recovery", dev.state("B", f"recovery-{index}") + "/recovery"
    created = dev.run("A", ["create", "--file", path, "--seed", str(rng.randrange(1, 10**6)), "--recovery", ra])
    t_create = now_ms()
    if variant.startswith("kill"):
        r2 = dev.run("A", ["save", "--file", path, "--title", f"A r2 case-{index}", "--recovery", ra])
        t_a = now_ms()
        seen = await_pub(dev, "B", path, r2.get("publicationID", "-"))
        prop = propagation_ms(dev, t_a, seen)
        boundary = variant[4:]
        marker = dev.state("A", f"recovery-{index}") + "/marker"
        os.makedirs(os.path.dirname(marker), exist_ok=True)
        dev.run("A", ["kill-at", "--file", path, "--boundary", boundary, "--recovery", ra, "--marker", marker])
        marker_ok = os.path.exists(marker) and open(marker).read() == boundary
        expected = f"A r2 case-{index}" if boundary in ("P3", "P4") else f"Killed at {boundary}"
        a, b, waited, settled = settle(dev, ["inspect", "--file", path], show_key)
        titles = {r.get("current", {}).get("title") for r in (a, b)}
        whole = all(r.get("current", {}).get("outcome") == "editable" for r in (a, b))
        cont = dev.run("B", ["save", "--file", path, "--title", f"B continues case-{index}", "--recovery", rb])
        ok = seen.get("result") == "observed" and marker_ok and settled and whole and titles == {expected} and cont.get("result") == "saved"
        return {"verdict": "pass" if ok else "fail", "variant": variant, "killedAtBoundary": marker_ok,
                "seenOnBothMacs": sorted(t or "" for t in titles), "expected": expected, "bContinued": cont.get("result"),
                "settledMs": waited, "propagationAtoBMs": prop}
    seen = await_pub(dev, "B", path, created.get("publicationID", "-"))
    prop = propagation_ms(dev, t_create, seen)
    dev.run("B", ["save", "--file", path, "--title", f"B r2 case-{index}", "--recovery", rb])
    b3 = dev.run("B", ["save", "--file", path, "--title", f"B r3 case-{index}", "--recovery", rb])
    t_b = dev.b_time(now_ms())
    back = await_pub(dev, "A", path, b3.get("publicationID", "-"))
    dev.run("A", ["corrupt", "--file", path])
    start = now_ms()
    damaged = {}
    while now_ms() - start < AWAIT_TIMEOUT * 1000:
        damaged = dev.run("B", ["open", "--file", path, "--recovery", rb])
        if damaged.get("outcome") in ("damaged", "unreadable"):
            break
        time.sleep(2)
    candidates = damaged.get("candidateRevisions", [])
    ok = (seen.get("result") == "observed" and back.get("result") == "observed"
          and damaged.get("outcome") in ("damaged", "unreadable") and bool(candidates) and max(candidates) == 2)
    return {"verdict": "pass" if ok else "fail", "variant": variant, "bOutcome": damaged.get("outcome"),
            "bCandidateRevisions": candidates, "bCandidateTitles": damaged.get("candidateTitles", []),
            "damageArrivedMs": now_ms() - start, "propagationAtoBMs": prop, "propagationBtoAMs": b_to_a_ms(dev, t_b, back)}


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
        freeze = os.environ.get("WW_FREEZE2_COMMIT", "")
        if not freeze or subprocess.run(["git", "-C", str(REPO), "merge-base", "--is-ancestor", freeze, "HEAD"]).returncode != 0:
            sys.exit("holdout requires WW_FREEZE2_COMMIT (the m1-freeze-2 merge) to be an ancestor of HEAD")
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
