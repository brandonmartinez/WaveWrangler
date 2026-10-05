#!/usr/bin/env python3
"""M1-DUR-025 two-device iCloud trial (headless on both Macs; synthetic documents only).

Recipe: registry M1-DUR-025 `recipeFreeze3` / `variantsFreeze3` (m1-freeze-3, protocol §4.3) with the
level-sampling FAIL rule of `recipeFreeze4` (m1-freeze-4, protocol §4.4). Host A = this Mac, host B = the other
Mac (same Apple account), driven over SSH. Every operation is a `wwpersist-probe` command (the WWPersistence /
WWSources code under test); this script only schedules, observes and judges. No GUI, no app launches, nothing
outside the trial folder and the per-run device-local state folders. Evidence names hosts only as host A / host B.

Usage:
  WW_DUR025_REMOTE=user@host scripts/dur025/run.py --split calibration|holdout|drill|dev [--remote user@host]
      [--counts show=N,library=N,relink=N,recovery=N] [--workers N] [--keep] [--cleanup-only]

Splits: calibration → 'calibration-f3', holdout → 'holdout-f3', drill → 'drill-f3' (the forced setupNotEstablished
drill: one relink slot with an injected unreachable '.nosync' fixture). Reserve refills use '<split>-reserve'.
Seeds: sha256("ww-m1-fixture|v1|M1-DUR-025|" + split + "|" + caseIndex), first 8 bytes big-endian.
Results: .build/dur025/<split>/results.jsonl (one line per case) and run-record.json.
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
# Host B as user@host: --remote or WW_DUR025_REMOTE. Never hard-code it here.
REMOTE = os.environ.get("WW_DUR025_REMOTE", "")
HOME = str(Path.home())
TRIAL_ROOT = f"{HOME}/Library/Mobile Documents/com~apple~CloudDocs/WaveWrangler-M1-Synthetic-Trial/dur025"
REPO = Path(__file__).resolve().parents[2]
SSH_CONTROL = "/tmp/ww-dur025-%C"
SSH_OPTIONS = ["ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=auto", "-o", f"ControlPath={SSH_CONTROL}",
               "-o", "ControlPersist=1800", "-o", "ServerAliveInterval=15"]
SSH = []  # SSH_OPTIONS + [remote], set in main()
SPLITS = {"calibration": "calibration-f3", "holdout": "holdout-f3", "drill": "drill-f3",
          "dev": "dev-f3"}   # dev: disclosed, uncounted mechanics check (Lead/coordinator ruling), never a frozen split
# Frozen cells (registry M1-DUR-025): calibration 10 / holdout 100.
DEFAULT_COUNTS = {"calibration": {"show": 3, "library": 3, "relink": 2, "recovery": 2},
                  "holdout": {"show": 30, "library": 30, "relink": 20, "recovery": 20},
                  "drill": {"relink": 1},
                  "dev": {"show": 1, "library": 1, "relink": 1, "recovery": 1}}
DEV_VARIANTS = {"show": ["staggered"], "library": ["concurrentCombine"], "relink": ["moved"], "recovery": ["aKilled"]}
CELL_NAMES = {"show": "show-conflict", "library": "library-conflict", "relink": "cross-machine-relink", "recovery": "recovery"}
STRATA = ["show", "library", "relink", "recovery"]
SETTLE_TIMEOUT = 420
AWAIT_TIMEOUT = 420
SETUP_WAIT = 420            # per fixture wait on host B; one download-request retry of the same length
ROUND_SETTLE = 600          # concurrentCombine / combine rounds
MAX_ROUNDS = 3
SAMPLE_INTERVAL = 2.0       # level samples: frozen as at least every 5 s
SAMPLE_MAX_GAP_MS = 5000
SNE_CAP_FRACTION = 0.2      # setupNotEstablished above 20% of a cell's frozen count → cell FAILS as incomplete
# Shared trigger time with a small seeded skew between the two hosts (the publications race).
RACE_SKEW_MS = [0, 0, 25, 50, 100, 250]
LIBRARY_EDITS = ["collection", "alias", "order", "recent"]
RELINK_VARIANTS = ["same", "moved", "replaced"]
RECOVERY_VARIANTS = ["bSaves", "bRelaunches", "aKilled"]
VARIANTS_FREEZE3 = {"show": {"simultaneous": 20, "staggered": 10}, "library": {"combineOnAThenB": 20, "concurrentCombine": 10}}
CALIBRATION_VARIANTS = {"show": ["simultaneous", "simultaneous", "staggered"],
                        "library": ["combineOnAThenB", "combineOnAThenB", "concurrentCombine"]}
SETUP_LOCK = threading.Lock()   # setupConcurrency: at most one case per run in its setup phase


def now_ms():
    return int(time.time() * 1000)


def seed_for(split, index):
    digest = hashlib.sha256(f"ww-m1-fixture|v1|{FIXTURE}|{split}|{index}".encode()).digest()
    return int.from_bytes(digest[:8], "big")


def redact(text):
    """Evidence privacy: no home paths (the trial folder is named by its iCloud Drive location)."""
    return text.replace(TRIAL_ROOT, "<iCloud Drive>/WaveWrangler-M1-Synthetic-Trial/dur025").replace(HOME, "<home>")


def variant_plan(split, cell, count):
    if split.startswith("dev"):
        return DEV_VARIANTS[cell][:count]
    if split.startswith("calibration") and cell in CALIBRATION_VARIANTS:
        return CALIBRATION_VARIANTS[cell][:count]
    if cell in VARIANTS_FREEZE3:
        names = [v for v, n in VARIANTS_FREEZE3[cell].items() for _ in range(n)]
        random.Random(seed_for(split, f"{cell}|variants")).shuffle(names)
        return (names * (count // len(names) + 1))[:count]
    names = RELINK_VARIANTS if cell == "relink" else RECOVERY_VARIANTS
    return [names[i % len(names)] for i in range(count)]


SSH_RETRIES = 4


def ssh_connection_failed(device, out):
    """An SSH-level failure (ssh exits 255: refused session, auth or connection), not the remote command's result."""
    return device == "B" and out.returncode == 255 and not any(l.startswith("{") for l in out.stdout.splitlines())


class Devices:
    def __init__(self, sha, split):
        self.local_probe = str(REPO / ".build/swiftpm/out/Products/Debug/wwpersist-probe")
        self.remote_dir = f"{HOME}/ww-uitest-runs/dur025-{sha}"
        self.remote_probe = f"{self.remote_dir}/wwpersist-probe"
        self.local_state = REPO / f".build/dur025/{split}/state"
        self.remote_state = f"{self.remote_dir}/state/{split}"
        self.offset_ms = 0  # B clock − A clock

    def run(self, device, args, timeout=900):
        """Runs one probe command on host 'A' or 'B'; returns its JSON line (or a harness error dict)."""
        if device == "A":
            cmd, env = [self.local_probe] + args, dict(os.environ, WW_HOST_PSEUDONYM="A")
        else:
            cmd, env = SSH + ["WW_HOST_PSEUDONYM=B " + shlex.join([self.remote_probe] + args)], None
        out, retries = None, 0
        for retries in range(SSH_RETRIES + 1):
            try:
                out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
            except subprocess.TimeoutExpired:
                return {"result": "harnessTimeout", "device": device, "args": args}
            if not ssh_connection_failed(device, out):
                break
            time.sleep(2 * (retries + 1))
        lines = [l for l in out.stdout.splitlines() if l.startswith("{")]
        if not lines:
            return {"result": "noOutput", "device": device, "status": out.returncode, "stderr": out.stderr[-400:]}
        data = json.loads(lines[-1])
        data["_status"] = out.returncode
        if retries:
            data["_sshRetries"] = retries
        return data

    def shell(self, device, script, timeout=120):
        cmd = ["bash", "-c", script] if device == "A" else SSH + [script]
        for attempt in range(SSH_RETRIES + 1):
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            if not ssh_connection_failed(device, out):
                break
            time.sleep(2 * (attempt + 1))
        return out

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

    def a_time(self, host, epoch_ms):
        """A host's wall-clock ms in A's clock."""
        if epoch_ms is None:
            return None
        return epoch_ms - self.offset_ms if host == "B" else epoch_ms

    def state(self, device, case_dir):
        return str(self.local_state / case_dir) if device == "A" else f"{self.remote_state}/{case_dir}"


class Case:
    """One slot (or reserve refill): its seed, variant, setup record and first product operation."""

    def __init__(self, split, index, cell, variant, slot=None, reserve_index=None, inject_unreachable=False):
        self.split, self.index, self.cell, self.variant = split, index, cell, variant
        self.key = f"{split}-{index}"
        self.slot = index if slot is None else slot
        self.reserve_index = reserve_index
        self.inject_unreachable = inject_unreachable
        self.rng = random.Random(seed_for(split, index))
        self.folder = f"{TRIAL_ROOT}/{split}/{cell}/case-{index}"
        self.setup = {"fixtures": [], "waits": [], "diagnostics": [], "downloadRequests": []}
        self.first_product_op = None

    def product_starts(self, dev, host, epoch_ms, what):
        """Records the first product operation (host clocks plus A's clock)."""
        if self.first_product_op is None and epoch_ms is not None:
            self.first_product_op = {"host": host, "what": what, "hostEpochMs": epoch_ms, "aClockMs": dev.a_time(host, epoch_ms)}


# ---------------------------------------------------------------- setup establishment (m1-freeze-3)

def fixture_matches(fixture, state):
    if fixture["kind"] == "publication":
        return state.get("publicationID") == fixture["publicationID"]
    return state.get("sha256") == fixture["sha256"]


def fixture_observed_on_b(dev, fixture, timeout):
    """Bounded wait on host B for one setup fixture (show or library publication ID, or source digest). Each poll
    also asks iCloud for the file, as in m1-freeze-2."""
    start = now_ms()
    while now_ms() - start < timeout * 1000:
        dev.run("B", ["await", "--file", fixture["path"], "--exists", "1", "--timeout", "5"], timeout=60)
        if fixture_matches(fixture, dev.run("B", ["fixture-state", "--file", fixture["path"]])):
            return True
        time.sleep(1)
    return False


def fixture_diagnostics(dev, case, fixture, attempt):
    states = {h: dev.run(h, ["fixture-state", "--file", fixture["path"]]) for h in ("A", "B")}
    for state in states.values():
        state.pop("_status", None)
    entry = {"fixture": fixture["name"], "attempt": attempt, "aClockMs": now_ms(), "A": states["A"], "B": states["B"],
             "aSetupPublication": fixture.get("aPublication")}
    case.setup["diagnostics"].append(entry)
    return entry


def classify_stall(fixture, diag):
    """setupNotEstablished only for a fixture that has NOT ARRIVED on host B while host A holds it as expected
    after a successful setup publication; every other setup outcome is a case FAILURE (freeze-3)."""
    a, b = diag["A"], diag["B"]
    for host, state in (("A", a), ("B", b)):
        if "present" not in state:   # the observer itself failed (e.g. SSH): never classified as a setup outcome
            return "harnessError", f"host {host} diagnostics unavailable ({state.get('result')}, status {state.get('status')})"
    expected_ok = lambda s: fixture_matches(fixture, s)  # noqa: E731
    a_ok = a.get("present") and not a.get("dataless") and expected_ok(a) and fixture.get("aPublicationOK", False)
    b_not_arrived = (not b.get("present")) or bool(b.get("dataless"))
    if b.get("present") and not b.get("dataless") and not expected_ok(b):
        return "failure", "fixture present on host B with an unexpected digest or publication ID"
    if not a_ok:
        return "failure", "fixture not readable on host A as expected, or host A's setup publication did not complete"
    if b_not_arrived:
        return "setupNotEstablished", "fixture has not arrived on host B"
    return "failure", "fixture present on host B but not observed as expected within the bound"


def establish(dev, case, fixtures):
    """Each fixture: wait ≤420 s on host B; on expiry host B requests the download and waits ≤420 s once more."""
    for fixture in fixtures:
        case.setup["fixtures"].append({k: v for k, v in fixture.items() if k != "aPublication"})
        diag = None
        for attempt in (1, 2):
            start = now_ms()
            observed = fixture_observed_on_b(dev, fixture, SETUP_WAIT)
            end = now_ms()
            case.setup["waits"].append({"fixture": fixture["name"], "attempt": attempt, "startAClockMs": start,
                                        "startBClockMs": dev.b_time(start), "observed": observed,
                                        "expiryAClockMs": None if observed else end, "expiryBClockMs": None if observed else dev.b_time(end)})
            if observed:
                break
            diag = fixture_diagnostics(dev, case, fixture, attempt)
            if attempt == 1:
                request = dev.run("B", ["request-download", "--file", fixture["path"]])
                request.pop("_status", None)
                case.setup["downloadRequests"].append({"fixture": fixture["name"], **request})
        else:
            outcome, reason = classify_stall(fixture, diag)
            return {"outcome": outcome, "reason": reason, "fixture": fixture["name"]}
    return {"outcome": "established"}


def setup_wait_order_ok(case):
    """Every setup wait's expiry strictly before the first product operation (A's clock)."""
    first = (case.first_product_op or {}).get("aClockMs")
    expiries = [w["expiryAClockMs"] for w in case.setup["waits"] if w["expiryAClockMs"] is not None]
    return first is None or all(e < first for e in expiries)


def source_writes(dev, expected):
    """Zero source writes (truth 5): every present, materialized source on each host has A's generated digest."""
    found = {}
    for host in ("A", "B"):
        for path, sha in expected.items():
            state = dev.run(host, ["fixture-state", "--file", path])
            if state.get("present") and not state.get("dataless"):
                found.setdefault(host, {})[redact(path)] = state.get("sha256") == sha
    return all(ok for per in found.values() for ok in per.values()), found


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



def version_counts_lib(a, b):
    return {h: {"unresolvedConflict": len(r.get("unresolvedConflictVersions", [])), "other": r.get("otherVersions")} for h, r in (("A", a), ("B", b))}



def recorded_baseline(store_path, source_id):
    """A's recorded fingerprint dates for one source, from the app's FileDeviceAccessStore file (JSONEncoder's
    default date strategy: seconds since 2001-01-01), as UTC ISO with ms."""
    import datetime as dt
    try:
        with open(store_path) as handle:
            records = json.load(handle).get("records", [])
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    record = next((r for r in records if str(r.get("sourceID", "")).upper() == source_id.upper()), None)
    if not record:
        return {"error": "no record"}
    fingerprint = (record.get("recordedIdentity") or {}).get("fingerprint") or {}

    def iso(knowledge):
        value = knowledge.get("value") if isinstance(knowledge, dict) else None
        if not isinstance(value, (int, float)):
            return value
        return dt.datetime.fromtimestamp(value + 978307200, dt.timezone.utc).isoformat(timespec="milliseconds")
    return {"creation": iso(fingerprint.get("creationDate")), "modification": iso(fingerprint.get("contentModificationDate")),
            "fileIdentifier": (fingerprint.get("fileIdentifier") or {}).get("value")}


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


# ---------------------------------------------------------------- show-conflict

def show_setup(dev, case):
    """Setup (serialized): host A publishes revision r; host B observes it. Returns (path, created, result-or-None)."""
    path = f"{case.folder}/Show.wwshow"
    os.makedirs(case.folder, exist_ok=True)
    ra = dev.state("A", f"{case.cell}-{case.key}") + "/recovery"
    created = dev.run("A", ["create", "--file", path, "--seed", str(case.rng.randrange(1, 10**6)), "--recovery", ra])
    a_state = dev.run("A", ["fixture-state", "--file", path])
    fixture = {"name": "show r", "kind": "publication", "path": path, "publicationID": created.get("publicationID", "-"),
               "sha256": a_state.get("sha256"), "aPublicationOK": created.get("result") == "saved",
               "aPublication": {"result": created.get("result"), "acknowledged": created.get("result") == "saved"}}
    if created.get("result") != "saved":
        return path, created, {"verdict": "fail", "reason": "host A's setup publication did not complete", "setupOutcome": "failure"}
    established = establish(dev, case, [fixture])
    if established["outcome"] != "established":
        return path, created, setup_result(established)
    return path, created, None


def setup_result(established):
    if established["outcome"] == "harnessError":
        return {"verdict": "harnessError", "setupOutcome": "harnessError", "reason": established["reason"],
                "stalledFixture": established["fixture"]}
    if established["outcome"] == "setupNotEstablished":
        return {"verdict": "setupNotEstablished", "setupOutcome": "setupNotEstablished", "reason": established["reason"],
                "stalledFixture": established["fixture"]}
    return {"verdict": "fail", "setupOutcome": "failure", "reason": f"setup: {established['reason']}", "stalledFixture": established["fixture"]}


def case_show(dev, case):
    with SETUP_LOCK:
        t_setup = now_ms()
        path, created, stopped = show_setup(dev, case)
        seen_ms = now_ms()
    if stopped:
        return stopped
    ra, rb = dev.state("A", f"show-{case.key}") + "/recovery", dev.state("B", f"show-{case.key}") + "/recovery"
    rng = case.rng
    title = {"A": f"A edit {rng.randrange(10**6)} {case.key}", "B": f"B edit {rng.randrange(10**6)} {case.key}"}
    if case.variant == "staggered":
        return show_staggered(dev, case, path, ra, rb, title)
    skew, first, t0, ta, tb = race_times(rng)
    with cf.ThreadPoolExecutor(2) as pool:
        fa = pool.submit(dev.run, "A", ["save", "--file", path, "--title", title["A"], "--recovery", ra, "--at-epoch-ms", str(ta)])
        fb = pool.submit(dev.run, "B", ["save", "--file", path, "--title", title["B"], "--recovery", rb, "--at-epoch-ms", str(dev.b_time(tb))])
        saves = {"A": fa.result(), "B": fb.result()}
    for host in ("A", "B"):
        case.product_starts(dev, host, saves[host].get("openedEpochMs"), "open of revision r")
    opens = sorted((dev.a_time(h, saves[h].get("openedEpochMs")) or 0, h) for h in saves)
    case.first_product_op = {"host": opens[0][1], "what": "each host's open of revision r", "aClockMs": opens[0][0],
                             "hostEpochMs": {h: saves[h].get("openedEpochMs") for h in saves}}
    a, b, settle_ms, settled, surfaced = settle_tracking(
        dev, ["inspect", "--file", path], show_key, lambda r: int(r.get("statusProviderConflicts") or 0), t0)
    reports = {"A": a, "B": b}
    acked = [h for h in ("A", "B") if saves[h].get("result") == "saved"]
    cur = {h: reports[h].get("current", {}) for h in ("A", "B")}
    one_current = (settled and all(cur[h].get("outcome") == "editable" for h in cur)
                   and reports["A"].get("sha256") and reports["A"].get("sha256") == reports["B"].get("sha256"))
    winner = next((h for h in ("A", "B") if cur["A"].get("publicationID") == saves[h].get("publicationID")), None)
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
            surfaced_on_loser = int(reports[host].get("statusProviderConflicts") or 0) > 0
            paths[host] = ("providerSurfaced" if in_version and surfaced_on_loser else
                           "silentLastWriterWins" if not in_version else "providerVersionNotSurfacedOnLoser")
            ok2 &= paths[host] == "providerSurfaced"
        else:
            paths[host] = f"noLocalAck:{result.get('result')}"
            ok2 = False
    lost = [h for h in ("A", "B") if paths.get(h) not in ("current", "appDetected", "providerSurfaced")]
    ok = bool(one_current) and winner is not None and ok2 and not lost and setup_wait_order_ok(case)
    return {"verdict": "pass" if ok else "fail", "setupOutcome": "established", "skewMs": skew, "first": first,
            "localAcks": acked, "saveResults": {h: saves[h].get("result") for h in saves},
            "detectionPath": paths, "winner": winner, "oneCurrentByteIdentical": bool(one_current),
            "settled": settled, "timeToSettleMs": settle_ms, "timeToSurfacingMs": surfaced,
            "versionCounts": version_counts(a, b),
            "conflictVersionComputers": sorted({v.get("savingComputer", "") for r in reports.values() for v in r.get("unresolvedConflictVersions", [])}),
            "siblings": {h: [s.get("name") for s in reports[h].get("siblings", [])] for h in reports},
            "setupPropagationMs": seen_ms - t_setup}


def show_staggered(dev, case, path, ra, rb, title):
    """variantsFreeze3 staggered: B opens r and holds (product phase starts); A publishes r+1; once A's r+1 is
    observed on B (bounded; expiry = FAIL), B publishes its edit from the stale base r. Expected: C3 base-check
    Conflict on B, B's candidate preserved, B never Saved, A's r+1 current and byte-identical on both hosts."""
    ready, go = dev.state("B", f"show-{case.key}") + "/ready", dev.state("B", f"show-{case.key}") + "/go"
    dev.shell("B", f"mkdir -p {shlex.quote(os.path.dirname(ready))}")
    t0 = now_ms()
    with cf.ThreadPoolExecutor(1) as pool:
        held = pool.submit(dev.run, "B", ["hold-save", "--file", path, "--title", title["B"], "--recovery", rb, "--ready", ready, "--go", go])
        while dev.shell("B", f"test -f {shlex.quote(ready)}").returncode != 0:
            if held.done():
                break
            time.sleep(0.5)
        a2 = dev.run("A", ["save", "--file", path, "--title", title["A"], "--recovery", ra])
        arrived = await_pub(dev, "B", path, a2.get("publicationID", "-"))
        dev.shell("B", f"touch {shlex.quote(go)}")
        result = held.result()
    case.product_starts(dev, "B", result.get("openedEpochMs"), "host B's open of revision r (held)")
    if arrived.get("result") != "observed":
        return {"verdict": "fail", "setupOutcome": "established", "reason": "A's r+1 not observed on host B within the bound (product phase)",
                "bResult": result.get("result")}
    candidate = dev.run("B", ["open", "--file", result.get("preservedCandidate", "-")]) if result.get("preservedCandidate") else {}
    a, b, settle_ms, settled, surfaced = settle_tracking(
        dev, ["inspect", "--file", path], show_key, lambda r: int(r.get("statusProviderConflicts") or 0), t0)
    ok = (a2.get("result") == "saved" and result.get("result") == "conflict" and candidate.get("title") == title["B"]
          and "saved" not in str(result.get("status", "")).lower()
          and settled and a.get("sha256") and a.get("sha256") == b.get("sha256")
          and a.get("current", {}).get("publicationID") == a2.get("publicationID") and setup_wait_order_ok(case))
    return {"verdict": "pass" if ok else "fail", "setupOutcome": "established", "aResult": a2.get("result"),
            "bResult": result.get("result"), "bStatus": result.get("status"), "bCandidatePreserved": candidate.get("title") == title["B"],
            "detectionPath": {"A": "current", "B": "appDetected" if result.get("result") == "conflict" else f"other:{result.get('result')}"},
            "localAcks": [h for h, r in (("A", a2), ("B", result)) if r.get("result") == "saved"],
            "aRevisionCurrentByteIdentical": bool(ok), "settled": settled, "timeToSettleMs": settle_ms, "timeToSurfacingMs": surfaced,
            "aToBArrivalMs": propagation_ms(dev, a2.get("publishedEpochMs") or t0, arrived), "versionCounts": version_counts(a, b)}


# ---------------------------------------------------------------- library-conflict

def independent_inclusion(version_entry, sampled_host, edits, current_report):
    """independentInclusionJudgement (m1-freeze-4): only from the harness's own record of the seeded edits of the
    host that wrote V, against the sampled current library model on that host (an ST-36 copy counts when it has
    exactly the seeded membership and order — `edit_presence`). No product merge code, judgement or fork base."""
    label = version_entry.get("savingComputer")
    writer = sampled_host if label == "this host" else ({"A": "B", "B": "A"}[sampled_host] if label == "other host" else None)
    current = current_report or {}
    if writer is None or not edits or writer not in edits or current.get("outcome") != "valid":
        return "undetermined", writer
    return ("included" if edit_presence(current.get("model", {}), edits[writer]) is not None else "not included"), writer


def judge_sample(report, host, edits):
    """m1-freeze-4 levelSamplingFailRule, plus the literal m1-freeze-3 rule for comparison."""
    lv = report.get("level") or {}
    level = lv.get("level")
    raw = len(report.get("unresolvedConflictVersions", []))
    versions, fail = [], False
    for v in lv.get("versions", []):
        decoded = v.get("outcome") == "valid"
        same = v.get("sameLibraryID") is True
        product_included = v.get("productVerdict") == "included"
        bases = v.get("forkBases") or []
        judgement, writer = independent_inclusion(v, host, edits, report.get("current"))
        harness = judgement == "included"
        exempt = decoded and same and product_included and bool(bases) and harness
        reason = None
        if product_included and judgement == "not included":
            fail, reason = True, "product included, harness not included"
        elif level == "ready" and not exempt:
            if (not decoded or not same) and v.get("noticeShown"):
                reason = "undecodable/different library with #119 notice"
            else:
                fail, reason = True, "ready with a non-exempt unresolved version"
        versions.append({"decode": v.get("outcome"), "sameLibraryID": v.get("sameLibraryID"), "productVerdict": v.get("productVerdict"),
                         "forkBases": bases, "harnessJudgement": judgement, "writer": writer, "noticeShown": v.get("noticeShown"),
                         "exempt": exempt, "disagreement": product_included != harness,
                         "savingComputer": v.get("savingComputer"), "failReason": reason})
    return {"level": level, "raw": raw, "versions": versions, "freeze4Fail": fail, "literalFreeze3Fail": level == "ready" and raw > 0,
            "holding": raw > 0 or level == "changedElsewhere", "unsampled": level in (None, "unsampled"),
            "unsampledReason": lv.get("reason")}


class Sampler:
    """Level samples on both hosts through the read-only load path, about every SAMPLE_INTERVAL s, for the
    whole product phase of a library case (which covers every holding window)."""

    def __init__(self, dev, case, libfile, edits):
        self.dev, self.case, self.libfile, self.edits = dev, case, libfile, edits
        self.samples = {"A": [], "B": []}
        self.stop = threading.Event()
        self.threads = [threading.Thread(target=self.loop, args=(h,), daemon=True) for h in ("A", "B")]
        for thread in self.threads:
            thread.start()

    def loop(self, host):
        base = self.dev.state(host, f"library-{self.case.key}")
        args = ["lib-inspect", "--file", self.libfile, "--level-settings", f"{base}/settings.json", "--level-recovery", f"{base}/recovery"]
        while not self.stop.is_set():
            started = time.time()
            report = self.dev.run(host, args, timeout=120)
            sample = judge_sample(report, host, self.edits)
            sample["aClockMs"] = self.dev.a_time(host, report.get("epochMs")) or now_ms()
            self.samples[host].append(sample)
            self.stop.wait(max(0.0, SAMPLE_INTERVAL - (time.time() - started)))

    def holding(self, host):
        return [s for s in self.samples[host] if s["holding"] and not s["unsampled"]]

    def finish(self):
        self.stop.set()
        for thread in self.threads:
            thread.join(timeout=180)

    def summary(self):
        out = {}
        for host, samples in self.samples.items():
            valid = [s for s in samples if not s["unsampled"]]
            gaps, prev = [], None
            for s in samples:
                if prev is not None and (prev["holding"] or s["holding"]):
                    gaps.append(s["aClockMs"] - prev["aClockMs"])
                prev = s if not s["unsampled"] else prev
            out[host] = {"samples": len(samples), "valid": len(valid), "holding": sum(1 for s in valid if s["holding"]),
                         "freeze4Fails": sum(1 for s in valid if s["freeze4Fail"]),
                         "literalFreeze3Fails": sum(1 for s in valid if s["literalFreeze3Fail"]),
                         "maxGapWhileHoldingMs": max(gaps) if gaps else None,
                         "levels": sorted({s["level"] for s in valid}),
                         "unsampledReasons": sorted({str(s["unsampledReason"]) for s in samples if s["unsampled"]})}
        return out

    def records(self):
        """Compact per-sample records (per version as frozen in m1-freeze-4)."""
        return {h: [{k: s[k] for k in ("aClockMs", "level", "raw", "versions", "freeze4Fail", "literalFreeze3Fail", "holding")}
                    for s in samples if not s["unsampled"]] for h, samples in self.samples.items()}


def wait_holding(sampler, host, timeout):
    """Ordering gate: ≥2 level samples on `host` while it holds the unresolved version (or app-detected L4)."""
    deadline = now_ms() + timeout * 1000
    while now_ms() < deadline:
        held = sampler.holding(host)
        if len(held) >= 2:
            return {"observedAClockMs": held[0]["aClockMs"], "secondAClockMs": held[1]["aClockMs"],
                    "firstWithin5s": True, "samplesHolding": len(held)}
        time.sleep(1)
    return None


def edit_target(edit):
    return {"collection": edit.get("name"), "alias": edit.get("alias"), "order": edit.get("name"), "recent": "recent"}[edit["kind"]]


def check_summary(op, edits):
    """combineSummaryCheck (freeze-3, item 2 of freeze-4): the Combine summary's not-carried items equal the
    harness-computed set (an ST-36 copy counts as carried), and every summary count matches the harness."""
    summary = op.get("combineSummary")
    before, after = op.get("combineBeforeModel") or {}, op.get("combineAfterModel") or {}
    if summary is None:
        return None
    not_carried = [e for e in edits.values() if edit_presence(after, e) is None]
    reported = list(summary.get("entryChangesNotCarried", [])) + list(summary.get("queuedChangesNotCarried", []))
    items_ok = len(reported) == len(not_carried) and all(any(str(edit_target(e)) in item for item in reported) for e in not_carried)
    before_names = {c["name"] for c in before.get("collections", [])}
    new = [c["name"] for c in after.get("collections", []) if c["name"] not in before_names]
    copies = [n for n in new if f" ({'from this Mac'}" in n]
    counts = {"collectionsKeptAsCopies": len(copies), "collectionsAdded": len(new) - len(copies),
              "showsAdded": len({e["showID"] for e in after.get("entries", [])} - {e["showID"] for e in before.get("entries", [])}),
              "recentItemsAdded": len(set(after.get("recents", [])) - set(before.get("recents", [])))}
    counts_ok = all(summary.get(k) == v for k, v in counts.items())
    return {"ok": items_ok and counts_ok, "summaryNotCarried": reported, "harnessNotCarried": [edit_target(e) for e in not_carried],
            "summaryCounts": {k: summary.get(k) for k in counts}, "harnessCounts": counts,
            "carried": [edit_target(e) for e in edits.values() if edit_presence(after, e) is not None]}


def product_load_ok(op):
    """'At every load': a product load showing ready must not leave an unresolved version outside the notice."""
    if op.get("levelAfterLoad") != "ready":
        return True
    return int(op.get("rawUnresolvedAfterLoad") or 0) <= int(op.get("unusableAfterLoad") or 0)


def case_library(dev, case):
    key, folder = case.key, case.folder
    libfile = f"{folder}/Library.wwlibrary"
    with SETUP_LOCK:
        t_setup = now_ms()
        os.makedirs(folder, exist_ok=True)
        moved = dev.run("A", lib_args(dev, "A", key, ["--seed-fixture", "1", "--move-to", folder]))
        setup_report = dev.run("A", ["lib-inspect", "--file", libfile])
        cur = setup_report.get("current", {})
        a_ok = cur.get("outcome") == "valid" and str(moved.get("move", "")).startswith("success")
        fixture = {"name": "library r", "kind": "publication", "path": libfile, "publicationID": cur.get("publicationID", "-"),
                   "sha256": cur.get("sha256"), "aPublicationOK": a_ok,
                   "aPublication": {"seeded": str(moved.get("seeded", ""))[:80], "move": str(moved.get("move", ""))[:80]}}
        if not a_ok:
            return {"verdict": "fail", "setupOutcome": "failure", "reason": "host A's setup publication did not complete"}
        established = establish(dev, case, [fixture])
        seen_ms = now_ms()
    if established["outcome"] != "established":
        return setup_result(established)
    setup = cur["model"]
    pub = cur["publicationID"]
    ops = []
    used = dev.run("B", lib_args(dev, "B", key, ["--use", folder]))
    ops.append(("B", "use", used))
    case.product_starts(dev, "B", used.get("loadStartedEpochMs"), "first product library load (host B)")
    pub_b = dev.run("B", ["lib-inspect", "--file", libfile]).get("current", {}).get("publicationID")
    if pub_b != pub:
        seen_a = poll_lib(dev, "A", libfile, lambda r: r.get("current", {}).get("publicationID") == pub_b)
        if seen_a.get("result") != "observed":
            return {"verdict": "fail", "setupOutcome": "established", "reason": "host B's use republished and A did not observe it (product phase)"}
    rng = case.rng
    kinds = {"A": rng.choice(LIBRARY_EDITS), "B": rng.choice(LIBRARY_EDITS)}
    args_a, edit_a = library_edit("A", kinds["A"], key, setup)
    args_b, edit_b = library_edit("B", kinds["B"], key, setup)
    edits = {"A": edit_a, "B": edit_b}
    skew, first, t0, ta, tb = race_times(rng)
    sampler = Sampler(dev, case, libfile, edits)
    try:
        with cf.ThreadPoolExecutor(2) as pool:
            fa = pool.submit(dev.run, "A", lib_args(dev, "A", key, args_a + ["--at-epoch-ms", str(ta)]))
            fb = pool.submit(dev.run, "B", lib_args(dev, "B", key, args_b + ["--at-epoch-ms", str(dev.b_time(tb))]))
            updates = {"A": fa.result(), "B": fb.result()}
        ops += [("A", "edit", updates["A"]), ("B", "edit", updates["B"])]
        # Ordering gate: B holds the unresolved version (or app-detected L4) for ≥2 samples before A combines;
        # in concurrentCombine, on both hosts before round 1. A must hold it too for its Combine to act.
        gate = {"B": wait_holding(sampler, "B", AWAIT_TIMEOUT)}
        gate["A"] = wait_holding(sampler, "A", AWAIT_TIMEOUT) if gate["B"] else None
        if not gate["B"] or not gate["A"]:
            sampler.finish()
            return {"verdict": "fail", "setupOutcome": "established", "variant": case.variant,
                    "reason": "ordering gate not met: " + ("host B" if not gate["B"] else "host A") + " never held the conflict within the bound",
                    "levelSampling": sampler.summary(), "edits": {h: edits[h]["kind"] for h in edits},
                    "updateResults": {h: updates[h].get("update") for h in updates}}
        rounds, converged, final = [], False, None
        for number in range(1, MAX_ROUNDS + 1):
            if number == 1 and case.variant == "concurrentCombine":
                hosts, at = ("A", "B"), now_ms() + 6000
            elif case.variant == "combineOnAThenB" and number > 1:
                # combineOnAThenBRounds: B combines if still in L4 (else the host still in L4), A preferred after round 2.
                in_l4 = [h for h in ("A", "B") if (rounds[-1]["finalLevels"].get(h) == "changedElsewhere")]
                hosts, at = (("B",) if number == 2 and "B" in in_l4 else (("A",) if "A" in in_l4 else tuple(in_l4[:1]) or ("A",))), None
            else:
                hosts, at = ("A",), None
            with cf.ThreadPoolExecutor(len(hosts)) as pool:
                futures = {h: pool.submit(dev.run, h, lib_args(dev, h, key, ["--combine", "1"] + (
                    ["--at-epoch-ms", str(at if h == "A" else dev.b_time(at))] if at else []))) for h in hosts}
                results = {h: f.result() for h, f in futures.items()}
            for h, r in results.items():
                ops.append((h, f"round{number}", r))
            a1, b1, ms1, settled1, _ = settle_tracking(dev, ["lib-inspect", "--file", libfile], lib_key, lambda r: 0, now_ms(), timeout=ROUND_SETTLE)
            finals = {h: dev.run(h, lib_args(dev, h, key, [])) for h in ("A", "B")}
            for h, r in finals.items():
                ops.append((h, f"round{number}-load", r))
            a2, b2, ms2, settled2, _ = settle_tracking(dev, ["lib-inspect", "--file", libfile], lib_key, lambda r: 0, now_ms(), timeout=ROUND_SETTLE)
            cur2 = {"A": a2.get("current", {}), "B": b2.get("current", {})}
            presence = {h: {host: edit_presence(cur2[host].get("model", {}), edits[h]) for host in ("A", "B")} for h in ("A", "B")}
            unresolved = {h: len(r.get("unresolvedConflictVersions", [])) for h, r in (("A", a2), ("B", b2))}
            byte_identical = all(c.get("outcome") == "valid" for c in cur2.values()) and cur2["A"].get("sha256") == cur2["B"].get("sha256")
            converged = (settled1 and settled2 and byte_identical and sum(unresolved.values()) == 0
                         and all(p in ("current", "copy") for per in presence.values() for p in per.values())
                         and all(finals[h].get("levelState") == "ready" for h in finals))
            rounds.append({"round": number, "hosts": list(hosts), "combined": {h: "combineSummary" in r for h, r in results.items()},
                           "levelsAtRound": {h: r.get("levelAfterLoad") for h, r in results.items()},
                           "settleMs": ms1, "settled": settled1, "afterLoadsSettleMs": ms2, "afterLoadsSettled": settled2,
                           "finalLevels": {h: finals[h].get("levelState") for h in finals}, "unresolved": unresolved,
                           "byteIdentical": byte_identical, "presence": presence, "converged": converged})
            # truth1LibraryClause at settle, per host: every unresolved version resolved or surfaced (L4 / #119 notice).
            settle_clause = {h: {"level": finals[h].get("levelState"), "rawUnresolvedAfterLoad": finals[h].get("rawUnresolvedAfterLoad"),
                                 "unusableWithNotice": finals[h].get("unusableAfterLoad"),
                                 "ok": int(finals[h].get("rawUnresolvedAfterLoad") or 0) == 0
                                 or finals[h].get("levelState") == "changedElsewhere"
                                 or int(finals[h].get("rawUnresolvedAfterLoad") or 0) <= int(finals[h].get("unusableAfterLoad") or 0)}
                             for h in finals}
            rounds[-1]["settleClause"] = settle_clause
            final = (a2, b2, presence, unresolved, settle_clause, byte_identical, settled1 and settled2)
            still_l4 = any(finals[h].get("levelState") == "changedElsewhere" for h in finals)
            done = converged if case.variant == "concurrentCombine" else not still_l4
            if done or not (settled1 and settled2):
                break
    finally:
        sampler.finish()
    combines = [(h, label, op) for h, label, op in ops if "combineSummary" in op]
    summary_checks = [{"host": h, "op": label, **(check_summary(op, edits) or {})} for h, label, op in combines]
    backups_ok = all(int(op.get("conflictBackups") or 0) >= int(op.get("providerConflictsAfterLoad") or 0) for _, _, op in combines)
    load_checks = [{"host": h, "op": label, "level": op.get("levelAfterLoad"), "rawUnresolved": op.get("rawUnresolvedAfterLoad"),
                    "unusable": op.get("unusableAfterLoad"), "ok": product_load_ok(op)} for h, label, op in ops if "levelAfterLoad" in op]
    sampling = sampler.summary()
    sampling_ok = all(s["freeze4Fails"] == 0 for s in sampling.values())
    cadence_ok = all((s["maxGapWhileHoldingMs"] or 0) <= SAMPLE_MAX_GAP_MS for s in sampling.values())
    l4 = {h: any(op.get("levelAfterLoad") == "changedElsewhere" for hh, _, op in ops if hh == h) for h in ("A", "B")}
    app_detected = {h: str(updates[h].get("update", "")).startswith("failed") for h in ("A", "B")}
    a2, b2, presence, unresolved, settle_clause, byte_identical, settled = final
    if case.variant == "concurrentCombine":
        outcome_ok = converged
    else:   # combineOnAThenB: one current byte-identical library holding both changes on both hosts + the settle clause
        outcome_ok = (settled and byte_identical and all(p in ("current", "copy") for per in presence.values() for p in per.values()))
    outcome_ok = outcome_ok and all(c["ok"] for c in settle_clause.values())
    ok = (outcome_ok and sampling_ok and cadence_ok and all(c.get("ok") for c in summary_checks) and bool(summary_checks)
          and backups_ok and all(c["ok"] for c in load_checks) and setup_wait_order_ok(case))
    return {"verdict": "pass" if ok else "fail", "setupOutcome": "established", "variant": case.variant, "skewMs": skew, "first": first,
            "edits": {h: edits[h]["kind"] for h in edits}, "localAcks": [h for h in ("A", "B") if str(updates[h].get("update", "")).startswith("published")],
            "updateResults": {h: updates[h].get("update") for h in updates},
            "detectionPath": "appDetected" if any(app_detected.values()) else "providerL4" if any(l4.values()) else "undetected",
            "l4OnLoad": l4, "orderingGate": gate, "rounds": rounds, "converged": converged, "presence": presence,
            "settleClause": settle_clause, "unresolvedAtSettle": unresolved,
            "summaryChecks": summary_checks, "backupsBeforeResolve": backups_ok, "productLoads": load_checks,
            "levelSampling": sampling, "levelSamplingOk": sampling_ok, "samplingCadenceOk": cadence_ok,
            "levelSamples": sampler.records(), "versionCounts": version_counts_lib(a2, b2),
            "conflictBackups": {h: max([int(op.get("conflictBackups") or 0) for hh, _, op in ops if hh == h] or [0]) for h in ("A", "B")},
            "setupPropagationMs": seen_ms - t_setup}


# ---------------------------------------------------------------- cross-machine-relink

def case_relink(dev, case):
    """Sources (random-byte files) with device access records on A only. Setup: A makes the sources and the show;
    the moved/replaced change is made before B opens; B observes every fixture. Product phase: B opens the show
    with no record (never resolved by path or name), then gets the location as an explicit choice."""
    variant, rng, folder = case.variant, case.rng, case.folder
    sources = f"{folder}/sources"
    records_a, records_b = dev.state("A", f"relink-{case.key}") + "/records", dev.state("B", f"relink-{case.key}") + "/records"
    expected = {}
    with SETUP_LOCK:
        made = dev.run("A", ["src-make", "--file", sources, "--count", "3", "--seed", str(rng.randrange(1, 2**40))])
        if made.get("result") != "made":
            return {"verdict": "fail", "setupOutcome": "failure", "reason": "host A's source setup failed", "variant": variant}
        files = [dict(f) for f in made["files"]]
        if case.inject_unreachable:
            # Forced setupNotEstablished drill: iCloud Drive does not sync names ending in .nosync.
            unreachable = files[2]["path"] + ".nosync"
            os.replace(files[2]["path"], unreachable)
            files[2]["path"] = unreachable
        show_path = f"{folder}/Show.wwshow"
        created = dev.run("A", ["create", "--file", show_path, "--seed", str(rng.randrange(1, 10**6))])
        show_id = read_show_id(show_path)
        source_ids = [str(uuid.UUID(int=rng.getrandbits(128))) for _ in files]
        expected = {f["path"]: f["sha256"] for f in files}
        for sid, f in zip(source_ids, files):
            dev.run("A", ["src-record", "--file", records_a, "--show", show_id, "--source", sid, "--source-file", f["path"]])
        show_state = dev.run("A", ["fixture-state", "--file", show_path])
        fixtures = [{"name": f"source-{i}", "kind": "digest", "path": f["path"], "sha256": f["sha256"], "aPublicationOK": True,
                     "aPublication": {"result": "made"}} for i, f in enumerate(files)]
        fixtures.append({"name": "show", "kind": "publication", "path": show_path, "publicationID": created.get("publicationID", "-"),
                         "sha256": show_state.get("sha256"), "aPublicationOK": created.get("result") == "saved",
                         "aPublication": {"result": created.get("result")}})
        established = establish(dev, case, fixtures)
        target = files[1]["path"]
        supplied = target
        if established["outcome"] == "established" and variant in ("moved", "replaced"):
            if variant == "moved":
                os.makedirs(f"{folder}/moved", exist_ok=True)
                supplied = f"{folder}/moved/{os.path.basename(target)}"
                os.replace(target, supplied)
                expected[supplied] = expected.pop(target)
                change = {"name": "moved source", "kind": "digest", "path": supplied, "sha256": expected[supplied], "aPublicationOK": True,
                          "aPublication": {"result": "moved"}}
            else:
                replacement = dev.run("A", ["src-make", "--file", f"{folder}/.replacement", "--count", "1", "--seed", str(rng.randrange(1, 2**40))])
                os.replace(replacement["files"][0]["path"], target)
                expected[target] = replacement["files"][0]["sha256"]
                change = {"name": "replaced source", "kind": "digest", "path": target, "sha256": expected[target], "aPublicationOK": True,
                          "aPublication": {"result": "replaced"}}
            established = establish(dev, case, [change])
            if established["outcome"] == "established" and variant == "moved" and not await_absent(dev, "B", target):
                established = {"outcome": "failure", "reason": "the moved source's old path did not disappear on host B", "fixture": "moved source"}
    if established["outcome"] != "established":
        result = setup_result(established)
        writes_ok, digests = source_writes(dev, expected)
        if not writes_ok:   # truth 5 is evaluated for setupNotEstablished too
            result.update({"verdict": "fail", "reason": result.get("reason", "") + "; a source digest changed"})
        result.update({"variant": variant, "zeroSourceWrites": writes_ok, "sourceDigestsOK": digests})
        return result
    opened = dev.run("B", ["open", "--file", show_path])
    case.product_starts(dev, "B", opened.get("openedEpochMs"), "host B's open of the show")
    b_eval = [dev.run("B", ["src-eval", "--file", records_b, "--show", show_id, "--source", sid]) for sid in source_ids]
    never_by_path = all(e.get("hasRecord") is False and e.get("access") == "needsRegrant" and not e.get("resolvedPath") for e in b_eval)
    sid = source_ids[1]
    unconfirmed = dev.run("B", ["src-relink", "--file", records_b, "--show", show_id, "--source", sid, "--source-file", supplied, "--confirm", "0"])
    confirmed = dev.run("B", ["src-relink", "--file", records_b, "--show", show_id, "--source", sid, "--source-file", supplied, "--confirm", "1"])
    b_after = dev.run("B", ["src-eval", "--file", records_b, "--show", show_id, "--source", sid])
    a_eval = dev.run("A", ["src-eval", "--file", records_a, "--show", show_id, "--source", sid])
    if variant == "same":
        a_ok = a_eval.get("location") == "present" and a_eval.get("identity") == "matchesRecorded"
    elif variant == "moved":
        a_ok = a_eval.get("location", "").startswith("moved") or a_eval.get("location", "").startswith("missing")
    else:
        a_ok = a_eval.get("identity", "").startswith(("mismatch", "changed")) or a_eval.get("access") in ("staleBookmark", "needsRegrant")
    digests = {h: {p: dev.run(h, ["digest", "--file", p]).get("sha256") for p in expected} for h in ("A", "B")}
    zero_writes = all(digests[h][p] == expected[p] for h in digests for p in expected)
    ok = (opened.get("outcome") == "editable" and never_by_path and str(unconfirmed.get("result", "")).startswith("confirmationRequired")
          and confirmed.get("result") == "applied" and b_after.get("access") == "granted" and a_ok and zero_writes and setup_wait_order_ok(case))
    return {"verdict": "pass" if ok else "fail", "setupOutcome": "established", "variant": variant,
            "bOpenedShow": opened.get("outcome"),
            "bWithoutRecord": [{k: e.get(k) for k in ("access", "location", "identity")} for e in b_eval],
            "neverResolvedByPathOrName": never_by_path, "bUnconfirmed": unconfirmed.get("result"),
            "bConfirmed": confirmed.get("result"), "bAfterRegrant": {k: b_after.get(k) for k in ("access", "identity")},
            "aReportsChangedSource": {k: redact(str(a_eval.get(k))) for k in ("location", "identity", "access")}, "aCorrect": a_ok,
            "zeroSourceWrites": zero_writes, "sourceFiles": len(expected)}


# ---------------------------------------------------------------- recovery

def case_recovery(dev, case):
    """A publishes r+1 while B holds unpublished edits on r (C2b checkpoint on B). Variants: B then saves (base
    check); B quits and relaunches before saving; A is killed at P4 or P5 while B is idle (B's checkpointed edit
    made first). Truth 6: unpublished work stays recoverable on its host; nothing reported Saved unless read back."""
    variant, rng = case.variant, case.rng
    with SETUP_LOCK:
        path, created, stopped = show_setup(dev, case)
    if stopped:
        stopped["variant"] = variant
        return stopped
    ra, rb = dev.state("A", f"recovery-{case.key}") + "/recovery", dev.state("B", f"recovery-{case.key}") + "/recovery"
    b_title, a_title = f"B unpublished {case.key}", f"A r2 {case.key}"
    if variant == "bSaves":
        ready, go = dev.state("B", f"recovery-{case.key}") + "/ready", dev.state("B", f"recovery-{case.key}") + "/go"
        dev.shell("B", f"mkdir -p {shlex.quote(os.path.dirname(ready))}")
        with cf.ThreadPoolExecutor(1) as pool:
            held = pool.submit(dev.run, "B", ["hold-save", "--file", path, "--title", b_title, "--recovery", rb, "--ready", ready, "--go", go])
            while dev.shell("B", f"test -f {shlex.quote(ready)}").returncode != 0 and not held.done():
                time.sleep(0.5)
            a2 = dev.run("A", ["save", "--file", path, "--title", a_title, "--recovery", ra])
            arrived = await_pub(dev, "B", path, a2.get("publicationID", "-"))
            dev.shell("B", f"touch {shlex.quote(go)}")
            result = held.result()
        case.product_starts(dev, "B", result.get("editedEpochMs"), "host B's first edit on revision r")
        candidate = dev.run("B", ["open", "--file", result.get("preservedCandidate", "-")]) if result.get("preservedCandidate") else {}
        a, b, settle_ms, settled = settle(dev, ["inspect", "--file", path], show_key)
        ok = (arrived.get("result") == "observed" and result.get("checkpointWritten") is True and result.get("result") == "conflict"
              and candidate.get("title") == b_title and int(result.get("editCheckpointsKept", 0)) >= 1
              and "saved" not in str(result.get("status", "")).lower()
              and settled and a.get("sha256") == b.get("sha256") and a.get("current", {}).get("title") == a_title and setup_wait_order_ok(case))
        return {"verdict": "pass" if ok else "fail", "setupOutcome": "established", "variant": variant, "bResult": result.get("result"),
                "bStatus": result.get("status"), "bCandidateTitle": candidate.get("title"), "bEditCheckpointsKept": result.get("editCheckpointsKept"),
                "currentOnBoth": a.get("current", {}).get("title"), "byteIdentical": a.get("sha256") == b.get("sha256"), "timeToSettleMs": settle_ms}
    quit_b = dev.run("B", ["checkpoint", "--file", path, "--title", b_title, "--recovery", rb])
    case.product_starts(dev, "B", quit_b.get("editedEpochMs"), "host B's first edit on revision r")
    if variant == "bRelaunches":
        a2 = dev.run("A", ["save", "--file", path, "--title", a_title, "--recovery", ra])
        arrived = await_pub(dev, "B", path, a2.get("publicationID", "-"))
        offer = dev.run("B", ["offer", "--file", path, "--recovery", rb])
        a, b, settle_ms, settled = settle(dev, ["inspect", "--file", path], show_key)
        ok = (quit_b.get("result") == "checkpointed" and "saved" not in str(quit_b.get("status", "")).lower()
              and arrived.get("result") == "observed" and offer.get("candidateTitle") == b_title
              and offer.get("mode") == "copyOnlyOlderRevision" and offer.get("currentTitle") == a_title
              and settled and a.get("sha256") == b.get("sha256") and setup_wait_order_ok(case))
        return {"verdict": "pass" if ok else "fail", "setupOutcome": "established", "variant": variant, "bQuitStatus": quit_b.get("status"),
                "bOfferOnRelaunch": {k: offer.get(k) for k in ("candidateTitle", "relation", "mode", "currentTitle")},
                "byteIdentical": a.get("sha256") == b.get("sha256"), "timeToSettleMs": settle_ms}
    boundary = rng.choice(["P4", "P5"])
    a2 = dev.run("A", ["save", "--file", path, "--title", a_title, "--recovery", ra])
    arrived = await_pub(dev, "B", path, a2.get("publicationID", "-"))
    marker = dev.state("A", f"recovery-{case.key}") + "/marker"
    os.makedirs(os.path.dirname(marker), exist_ok=True)
    killed = dev.run("A", ["kill-at", "--file", path, "--boundary", boundary, "--recovery", ra, "--marker", marker])
    marker_ok = os.path.exists(marker) and open(marker).read() == boundary
    expected = a_title if boundary == "P4" else f"Killed at {boundary}"
    a, b, settle_ms, settled = settle(dev, ["inspect", "--file", path], show_key)
    titles = {r.get("current", {}).get("title") for r in (a, b)}
    reopened_b = dev.run("B", ["open", "--file", path, "--recovery", rb])
    offer = dev.run("B", ["offer", "--file", path, "--recovery", rb])
    ok = (quit_b.get("result") == "checkpointed" and arrived.get("result") == "observed" and marker_ok and killed.get("result") != "saved"
          and settled and a.get("sha256") == b.get("sha256") and titles == {expected} and reopened_b.get("outcome") == "editable"
          and offer.get("candidateTitle") == b_title and setup_wait_order_ok(case))
    return {"verdict": "pass" if ok else "fail", "setupOutcome": "established", "variant": f"aKilled{boundary}", "killedAtBoundary": marker_ok,
            "aReportedSaved": killed.get("result") == "saved", "currentOnBoth": sorted(t or "" for t in titles), "expected": expected,
            "bCheckpointStillOffered": offer.get("candidateTitle") == b_title,
            "byteIdentical": a.get("sha256") == b.get("sha256"), "timeToSettleMs": settle_ms}


# ---------------------------------------------------------------- run

CASES = {"show": case_show, "library": case_library, "relink": case_relink, "recovery": case_recovery}


def run_case(dev, case):
    started = now_ms()
    try:
        result = CASES[case.cell](dev, case)
    except Exception as error:  # a harness defect is recorded, never hidden
        result = {"verdict": "harnessError", "exception": repr(error)}
    result.setdefault("variant", case.variant)
    result.update({"stratum": case.cell, "split": case.split, "caseIndex": case.index, "slot": case.slot,
                   "reserveIndex": case.reserve_index, "seed": seed_for(case.split, case.index), "durationMs": now_ms() - started,
                   "setup": case.setup, "firstProductOperation": case.first_product_op,
                   "setupWaitsBeforeFirstProductOperation": setup_wait_order_ok(case)})
    return json.loads(redact(json.dumps(result)))


def git(*args):
    return subprocess.run(["git", "-C", str(REPO)] + list(args), capture_output=True, text=True).stdout.strip()


HOST_FIELDS = ["model", "cpu", "cores", "memoryBytes", "macOS", "macOSBuild", "xcode", "sdk", "swift", "probeSha256"]


def host_record(dev, device):
    """hostLabels (m1-freeze-3): pseudonymous host A / host B; no hostname, computer name or account identifier."""
    probe = dev.local_probe if device == "A" else dev.remote_probe
    script = ("sysctl -n hw.model; sysctl -n machdep.cpu.brand_string; sysctl -n hw.ncpu; sysctl -n hw.memsize; "
              "sw_vers -productVersion; sw_vers -buildVersion; xcodebuild -version 2>/dev/null | tr '\\n' ' '; echo; "
              f"xcrun --show-sdk-version 2>/dev/null; swift --version 2>/dev/null | head -1; shasum -a 256 {shlex.quote(probe)} | cut -d' ' -f1")
    out = dev.shell(device, script).stdout.split("\n")
    values = [line.strip() for line in out] + [""] * len(HOST_FIELDS)
    return {"pseudonym": f"host {device}", **dict(zip(HOST_FIELDS, values))}


def cleanup(dev, split):
    """Deletes this run's trial subfolder (iCloud propagates the deletion) and both hosts' device-local state."""
    target = f"{TRIAL_ROOT}/{split}"
    existed = os.path.exists(target)
    shutil.rmtree(target, ignore_errors=True)
    shutil.rmtree(dev.local_state, ignore_errors=True)
    subprocess.run(SSH + [f"rm -rf {shlex.quote(dev.remote_state)}"])
    return {"deleted": redact(target), "existedBefore": existed, "existsAfterLocally": os.path.exists(target),
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--split", choices=list(SPLITS), default="calibration")
    parser.add_argument("--counts", default="")
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--keep", action="store_true", help="don't delete the trial folder afterwards")
    parser.add_argument("--cleanup-only", action="store_true")
    parser.add_argument("--remote", default=REMOTE, help="host B as user@host (default: $WW_DUR025_REMOTE)")
    args = parser.parse_args()
    if not args.remote:
        sys.exit("host B is required: --remote user@host or WW_DUR025_REMOTE")
    if args.workers > 6:
        sys.exit("setupConcurrency: at most 6 concurrent case workers")
    SSH[:] = SSH_OPTIONS + [args.remote]
    split = SPLITS[args.split]
    reserve_split = f"{split}-reserve"
    sha = git("rev-parse", "--short", "HEAD")
    dev = Devices(sha, split)
    if args.cleanup_only:
        print(json.dumps(cleanup(dev, split)))
        return
    counts = dict(DEFAULT_COUNTS[args.split])
    for part in filter(None, args.counts.split(",")):
        key, value = part.split("=")
        counts[key] = int(value)
    if args.split == "holdout":
        if git("status", "--porcelain"):
            sys.exit("holdout requires a clean tree")
        # The coordinator's required commits: m1-freeze-3, m1-freeze-4 and the #133 merge (all on main).
        required = [c for c in os.environ.get("WW_REQUIRED_COMMITS", "").split(",") if c]
        if len(required) < 3:
            sys.exit("holdout requires WW_REQUIRED_COMMITS=<freeze-3>,<freeze-4>,<#133 merge>")
        for commit in required:
            if subprocess.run(["git", "-C", str(REPO), "merge-base", "--is-ancestor", commit, "HEAD"]).returncode != 0:
                sys.exit(f"holdout requires {commit} to be an ancestor of HEAD")
    if os.environ.get("WW_SAME_ACCOUNT_ATTESTED") != "1":
        sys.exit("hostLabels: set WW_SAME_ACCOUNT_ATTESTED=1 (same Apple account, operator-attested)")
    out_dir = REPO / f".build/dur025/{split}"
    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(dev.local_state, ignore_errors=True)
    subprocess.run(SSH + [f"mkdir -p {shlex.quote(dev.remote_dir)} && rm -rf {shlex.quote(dev.remote_state)}"], check=True)
    subprocess.run(["rsync", "-a", "-e", f"ssh -o ControlPath={SSH_CONTROL}", dev.local_probe, f"{args.remote}:{dev.remote_dir}/"], check=True)
    hosts = {"A": host_record(dev, "A"), "B": host_record(dev, "B")}
    missing = {h: [f for f in HOST_FIELDS if not hosts[h].get(f)] for h in hosts}
    if any(missing.values()) or hosts["A"]["probeSha256"] != hosts["B"]["probeSha256"]:
        sys.exit(f"invalid run: host labels missing {missing} or probe hashes differ")
    trees = {p: git("rev-parse", f"HEAD:{p}") for p in ["Packages/WaveWranglerKit/Sources/WWPersistence",
                                                        "Packages/WaveWranglerKit/Sources/WWSources",
                                                        "Packages/WaveWranglerKit/Sources/WWPersistenceProbe", "scripts/dur025"]}
    record = {"fixture": FIXTURE, "split": split, "reserveSplit": reserve_split, "commit": git("rev-parse", "HEAD"),
              "freeze": "m1-freeze-3 recipe with the m1-freeze-4 level-sampling rule", "protocol": "ww-003-fixture-protocol.md §4.3, §4.4",
              "requiredCommits": os.environ.get("WW_REQUIRED_COMMITS", ""), "cells": CELL_NAMES,
              "label": "two-host evidence (host A + host B), same Apple account, iCloud Drive, synthetic data only",
              "sameAppleAccount": "operator-attested", "hosts": hosts,
              "trees": {"A": trees, "B": {"builtFrom": trees, "attestedBy": "probe sha256 equal on both hosts"}},
              "clockOffsetStart": dev.measure_offset(), "counts": counts,
              "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "trialRoot": redact(TRIAL_ROOT)}
    plan, index = [], 0
    for cell in STRATA:
        for variant in variant_plan(split, cell, counts.get(cell, 0)):
            plan.append(Case(split, index, cell, variant, inject_unreachable=args.split == "drill"))
            index += 1
    # The cap is 20% of each cell's frozen HOLDOUT count (6 show/library, 4 relink/recovery), for every split.
    caps = {cell: int(SNE_CAP_FRACTION * DEFAULT_COUNTS["holdout"][cell]) for cell in STRATA}
    sne = {cell: 0 for cell in STRATA}
    incomplete = {}
    reserve_next = 0
    results_path = out_dir / "results.jsonl"
    with open(results_path, "w") as results, cf.ThreadPoolExecutor(args.workers) as pool:
        pending = {pool.submit(run_case, dev, case): case for case in plan}
        while pending:
            done, _ = cf.wait(pending, return_when=cf.FIRST_COMPLETED)
            for future in done:
                case = pending.pop(future)
                line = future.result()
                results.write(json.dumps(line, sort_keys=True) + "\n")
                results.flush()
                print(f"[{case.cell} {case.key} {case.variant}] {line['verdict']} {line.get('reason', '')}", flush=True)
                if line["verdict"] == "setupNotEstablished":
                    sne[case.cell] += 1
                    if sne[case.cell] > caps[case.cell]:
                        incomplete[case.cell] = f"setupNotEstablished {sne[case.cell]} > cap {caps[case.cell]}"
                    elif case.cell not in incomplete:
                        refill = Case(reserve_split, reserve_next, case.cell, case.variant, slot=case.slot, reserve_index=reserve_next)
                        reserve_next += 1
                        pending[pool.submit(run_case, dev, refill)] = refill
    record["setupNotEstablished"] = sne
    record["setupNotEstablishedCap"] = caps
    record["cellsIncomplete"] = incomplete
    record["reserveIndicesUsed"] = reserve_next
    record["clockOffsetEnd"] = dev.measure_offset()
    record["finishedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if not args.keep:
        record["cleanup"] = cleanup(dev, split)
    (out_dir / "run-record.json").write_text(json.dumps(record, indent=2, sort_keys=True))
    print(json.dumps({"results": redact(str(results_path)), "record": redact(str(out_dir / "run-record.json"))}))


if __name__ == "__main__":
    main()
