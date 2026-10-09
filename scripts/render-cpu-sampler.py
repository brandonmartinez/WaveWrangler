#!/usr/bin/env python3
"""Bounded, descendant-aware macOS CPU sampling for render calibration and holdout."""

import argparse
import ctypes
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages/WaveWranglerKit"
FREEZE = ROOT / "docs/m2/fixtures/m2-freeze-render-4.json"
INTERVAL_NS = 100_000_000
MAX_GAP_NS = 1_000_000_000
CPU_LIMIT = 400.0
PROC_PIDTBSDINFO = 3
PROC_PIDTASKINFO = 4


class BSDInfo(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint32), ("status", ctypes.c_uint32),
        ("xstatus", ctypes.c_uint32), ("pid", ctypes.c_uint32),
        ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32),
        ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32),
        ("rgid", ctypes.c_uint32), ("svuid", ctypes.c_uint32),
        ("svgid", ctypes.c_uint32), ("reserved", ctypes.c_uint32),
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
        ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
        ("pjobc", ctypes.c_uint32), ("tdev", ctypes.c_uint32),
        ("tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32),
        ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64),
    ]


class TaskInfo(ctypes.Structure):
    _fields_ = [
        ("virtual_size", ctypes.c_uint64), ("resident_size", ctypes.c_uint64),
        ("total_user", ctypes.c_uint64), ("total_system", ctypes.c_uint64),
        ("threads_user", ctypes.c_uint64), ("threads_system", ctypes.c_uint64),
    ] + [(name, ctypes.c_int32) for name in (
        "policy", "faults", "pageins", "cow_faults", "messages_sent",
        "messages_received", "syscalls_mach", "syscalls_unix", "csw",
        "threadnum", "numrunning", "priority",
    )]


class SamplerError(RuntimeError):
    pass


class CPUExceeded(SamplerError):
    pass


class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def mach_timebase():
    clock = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    clock.mach_timebase_info.argtypes = (ctypes.POINTER(MachTimebase),)
    clock.mach_timebase_info.restype = ctypes.c_int
    value = MachTimebase()
    if clock.mach_timebase_info(ctypes.byref(value)) != 0 or not value.denom or not value.numer:
        raise SamplerError("mach_timebase_info did not return a valid CPU tick-to-nanosecond factor")
    return value.numer, value.denom


TIMEBASE = mach_timebase()


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.STDOUT).strip()


def live_pid(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class ProcessSampler:
    def __init__(self):
        self.api = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.api.proc_listchildpids.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_int)
        self.api.proc_listchildpids.restype = ctypes.c_int
        self.api.proc_pidinfo.argtypes = (
            ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int
        )
        self.api.proc_pidinfo.restype = ctypes.c_int
        self.seen = set()

    def children(self, pid):
        count = self.api.proc_listchildpids(pid, None, 0)
        if count < 0:
            if ctypes.get_errno() == errno.ESRCH or not live_pid(pid):
                return []
            raise SamplerError(f"proc_listchildpids({pid}) returned {count}, errno={ctypes.get_errno()}")
        capacity = max(16, count * 2 + 4)
        pids = (ctypes.c_int * capacity)()
        found = self.api.proc_listchildpids(pid, pids, ctypes.sizeof(pids))
        if found < 0 or found >= capacity:
            if found < 0 and (ctypes.get_errno() == errno.ESRCH or not live_pid(pid)):
                return []
            raise SamplerError(f"proc_listchildpids({pid}) found={found}, capacity={capacity}, errno={ctypes.get_errno()}")
        return [child for child in pids[:found] if child > 0]

    def info(self, pid, flavor, struct_type):
        result = struct_type()
        size = ctypes.sizeof(result)
        nbytes = self.api.proc_pidinfo(pid, flavor, 0, ctypes.byref(result), size)
        if nbytes != size:
            if ctypes.get_errno() == errno.ESRCH or not live_pid(pid):
                return None
            raise SamplerError(f"proc_pidinfo({pid}, {flavor}) returned {nbytes}/{size}, errno={ctypes.get_errno()}")
        return result

    def snapshot(self, root_pid):
        begin = time.monotonic_ns()
        queue = [root_pid, *(identity[0] for identity in self.seen)]
        inspected = set()
        observations = {}
        while queue:
            pid = queue.pop()
            if pid in inspected:
                continue
            inspected.add(pid)
            info = self.info(pid, PROC_PIDTBSDINFO, BSDInfo)
            if info is None:
                continue
            identity = (pid, info.start_sec, info.start_usec)
            if pid != root_pid and identity not in self.seen and info.ppid not in inspected:
                raise SamplerError(f"unexpected parent for newly observed PID {pid}: {info.ppid}")
            task = self.info(pid, PROC_PIDTASKINFO, TaskInfo)
            if task is None:
                continue
            name = info.name or info.comm
            # pti_threads_* is already included in pti_total_*; adding both doubles live CPU.
            observations[identity] = (
                info.ppid, info.pgid, name.decode("utf-8", "replace"),
                task.total_user + task.total_system,
            )
            queue.extend(self.children(pid))
        end = time.monotonic_ns()
        self.seen.update(observations)
        return begin, end, observations


def calculate(previous, current, timebase=TIMEBASE):
    prev_begin, prev_end, prev = previous
    begin, end, observations = current
    gap = end - prev_begin
    if gap > MAX_GAP_NS:
        raise SamplerError(f"missed CPU coverage: conservative snapshot gap {gap / 1e9:.6f}s > 1s")
    if begin > end or prev_begin > prev_end or end <= prev_end:
        raise SamplerError("non-monotonic process snapshots")
    cpu_by_pid = {}
    for identity, row in observations.items():
        prior = prev.get(identity)
        if prior is not None and row[3] < prior[3]:
            raise SamplerError(f"task CPU counter decreased for PID {identity[0]}")
        elapsed_ticks = row[3] - prior[3] if prior is not None else row[3]
        cpu_by_pid[identity] = 100 * elapsed_ticks * timebase[0] / (
            (end - prev_end) * timebase[1]
        )
    tree_cpu = sum(cpu_by_pid.values())
    if not math.isfinite(tree_cpu) or tree_cpu >= CPU_LIMIT:
        raise CPUExceeded(f"whole-tree CPU {tree_cpu:.2f}% reaches or exceeds strict {CPU_LIMIT:.0f}% limit")
    return gap, tree_cpu, cpu_by_pid


def self_test():
    base = 10_000_000_000
    root = (100, 1, 0)
    helper = (101, 2, 0)
    prev = (base, base + 20_000_000, {root: (0, 100, "swift-test", 10_000_000)})
    current = (base + 200_000_000, base + 220_000_000, {
        root: (0, 100, "swift-test", 20_000_000),
        helper: (100, 101, "swiftpm-testing-helper", 200_000_000),
    })
    gap, tree, values = calculate(prev, current, (1, 1))
    assert gap == 220_000_000 and tree == 105.0 and len(values) == 2
    missed = (base + 1_100_000_000, base + 1_120_000_000, current[2])
    try:
        calculate(prev, missed, (1, 1))
    except SamplerError as error:
        assert "missed CPU coverage" in str(error)
    else:
        raise AssertionError("missed-sample injection was not detected")
    try:
        calculate(prev, (current[0], current[1], {
            root: (0, 100, "swift-test", 810_000_000),
        }), (1, 1))
    except SamplerError as error:
        assert "reaches or exceeds" in str(error)
    else:
        raise AssertionError("exactly 400% CPU was not rejected")
    print("PASS: descendant CPU aggregation, missed-sample and exact-400% rejection")


def preflight(mode):
    load = command("sysctl", "-n", "vm.loadavg").strip("{} ").split()[0]
    if float(load) > 24:
        raise SamplerError(f"one-minute load {load} exceeds 24; {mode} not started")
    processes = command("ps", "-A", "-o", "comm=").splitlines()
    builds = sum(p.endswith(("/xcodebuild", "/swift-build", "/swift-test")) for p in processes)
    helpers = sum(p.endswith("swiftpm-testing-helper") for p in processes)
    maximum_helpers = 1 if mode == "calibration" else 0
    if builds > 2 or helpers > maximum_helpers:
        raise SamplerError(f"{builds} other native builds and {helpers} test helpers; {mode} not started")
    details = {"mode": mode, "host": socket.gethostname(), "oneMinuteLoad": load,
               "otherNativeBuilds": builds, "otherTestHelpers": helpers,
               "macOS": command("sw_vers", "-productVersion"),
               "Xcode": command("xcodebuild", "-version").replace("\n", " / "),
               "Swift": command("swift", "--version").splitlines()[0],
               "sourceTree": command("git", "rev-parse", "HEAD:Packages/WaveWranglerKit/Sources/WWRender"),
               "testTree": command("git", "rev-parse", "HEAD:Packages/WaveWranglerKit/Tests/WWRenderTests"),
               "samplerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               "machTimebaseNanosecondsPerTick": f"{TIMEBASE[0]}/{TIMEBASE[1]}"}
    if mode == "holdout":
        if command("git", "status", "--porcelain"):
            raise SamplerError("holdout requires a clean committed tree")
        command("git", "cat-file", "-e", f"HEAD:{FREEZE.relative_to(ROOT)}")
        freeze = json.loads(FREEZE.read_text(encoding="utf-8"))
        for path, tree in (("Sources/WWRender", details["sourceTree"]),
                           ("Tests/WWRenderTests", details["testTree"])):
            if freeze["pinnedTrees"][path] != tree:
                raise SamplerError(f"{path} differs from prospective freeze")
        if freeze["cpuTelemetry"]["runnerSHA256"] != details["samplerSHA256"]:
            raise SamplerError("CPU sampler differs from prospective freeze")
        if (freeze["cpuTelemetry"]["wholeTreeCPUPercentLimitExclusive"] != CPU_LIMIT
                or freeze["cpuTelemetry"]["sampleIntervalSeconds"] != INTERVAL_NS / 1e9
                or freeze["cpuTelemetry"]["maximumSampleGapSeconds"] != MAX_GAP_NS / 1e9):
            raise SamplerError("prospective freeze changes the calibrated CPU protocol")
        if freeze["holdoutSplit"] != "holdout-4":
            raise SamplerError("wrong holdout split in prospective freeze")
        original = json.loads((FREEZE.parent / "m2-freeze-render.json").read_text(encoding="utf-8"))
        if freeze["gateValues"] != original["gateValues"]:
            raise SamplerError("prospective freeze changes the original objective gates")
        if freeze["splits"]["holdout"]["cases"] != 48 or freeze["splits"]["holdout"]["plusMultiSpan"] != 1:
            raise SamplerError("prospective freeze changes the 48+1 holdout cases")
        details["freezeSHA"] = command("git", "rev-parse", "HEAD")
    return details


def run(mode, output):
    if not output.is_absolute() or output == ROOT or ROOT in output.resolve().parents:
        raise SamplerError("evidence directory must be an absolute path outside the repository")
    if output.exists():
        raise SamplerError(f"evidence directory already exists: {output}")
    details = preflight(mode)
    output.mkdir(parents=True, exist_ok=False)
    (output / "preflight.json").write_text(json.dumps(details, indent=2) + "\n")
    test_name = ("calibrationSplitMeetsEveryObjectiveGate" if mode == "calibration"
                 else "holdoutSplitMeetsEveryFrozenGate")
    env = os.environ.copy()
    env["SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"] = "1"
    env["WW_RENDER_RECORDS_DIR"] = str(output)
    env["WW_RENDER_CALIBRATION" if mode == "calibration" else "WW_M2_RENDER_4_HOLDOUT"] = "1"
    args = ["swift", "test", "--package-path", str(PACKAGE), "--scratch-path",
            str(ROOT / ".build/swiftpm"), "--jobs", "4", "--no-parallel", "--filter", test_name]
    (output / "command.txt").write_text(" ".join(args) + "\n")
    sampler = ProcessSampler()
    samples = []
    max_pid = 0.0
    max_tree = 0.0
    max_gap = 0
    helper_samples = 0
    errors = []
    disappeared = set()
    cpu_failure = False
    started_utc = datetime.now(timezone.utc).isoformat()
    launch_ns = time.monotonic_ns()
    with (output / "run.log").open("w") as log:
        proc = subprocess.Popen(args, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=True)
        def interrupted(signum, _frame):
            raise SamplerError(f"sampler interrupted by signal {signum}")

        previous_handler = signal.signal(signal.SIGTERM, interrupted)
        try:
            while True:
                current = sampler.snapshot(proc.pid)
                samples.append(current)
                if current[1] - launch_ns > MAX_GAP_NS and len(samples) == 1:
                    raise SamplerError("first process snapshot started more than 1s after launch")
                if len(samples) == 1:
                    startup_cpu = {identity: 100 * row[3] * TIMEBASE[0] /
                                   ((current[1] - launch_ns) * TIMEBASE[1])
                                   for identity, row in current[2].items()}
                    max_tree = sum(startup_cpu.values())
                    max_pid = max((0.0, *startup_cpu.values()))
                    if max_tree >= CPU_LIMIT:
                        raise CPUExceeded(f"launch whole-tree CPU {max_tree:.2f}% reaches or exceeds strict 400% limit")
                else:
                    previous_ids = set(samples[-2][2])
                    current_ids = set(current[2])
                    if current_ids & disappeared:
                        raise SamplerError(f"PID returned after an unobserved interval: {current_ids & disappeared}")
                    disappeared.update(previous_ids - current_ids)
                    gap, tree, cpu_by_pid = calculate(samples[-2], current)
                    max_gap = max(max_gap, gap)
                    max_tree = max(max_tree, tree)
                    max_pid = max((max_pid, *cpu_by_pid.values()))
                if any("swiftpm-testing-helper" in row[2] for row in current[2].values()):
                    helper_samples += 1
                if proc.poll() is not None:
                    break
                if not any(identity[0] == proc.pid for identity in current[2]):
                    raise SamplerError("running swift-test PID absent from snapshot")
                time.sleep(max(0, (current[0] + INTERVAL_NS - time.monotonic_ns()) / 1e9))
            exit_code = proc.wait()
        except SamplerError as error:
            errors.append(str(error))
            cpu_failure = isinstance(error, CPUExceeded)
            print(f"sampling failed: {error}", file=sys.stderr, flush=True)
            for identity in samples[-1][2] if samples else ():
                pid, sec, usec = identity
                try:
                    info = sampler.info(pid, PROC_PIDTBSDINFO, BSDInfo)
                    if info is not None and (info.start_sec, info.start_usec) == (sec, usec):
                        os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                except PermissionError as stop_error:
                    errors.append(f"could not stop owned PID {pid}: {stop_error}")
            if proc.poll() is None:
                try:
                    proc.terminate()
                except ProcessLookupError:
                    pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            exit_code = proc.returncode
        finally:
            signal.signal(signal.SIGTERM, previous_handler)
    end_ns = time.monotonic_ns()
    if not samples or samples[0][1] - launch_ns > MAX_GAP_NS:
        errors.append("missing launch coverage")
    if samples and end_ns - samples[-1][0] > MAX_GAP_NS:
        errors.append("missing exit coverage")
    if not helper_samples:
        errors.append("no SwiftPM testing-helper observation")

    with (output / "samples.tsv").open("w") as stream:
        stream.write("index\tbeginMonotonicNS\tendMonotonicNS\tconservativeGapSeconds\twholeTreeCPUPercent\tpids\n")
        for index, sample in enumerate(samples):
            gap = 0
            if not index:
                tree = sum(100 * row[3] * TIMEBASE[0] /
                           ((sample[1] - launch_ns) * TIMEBASE[1])
                           for row in sample[2].values())
            else:
                gap = (sample[1] - samples[index - 1][0]) / 1e9
                # Preserve the raw gap even when a sample exceeds the protocol limit.
                try:
                    _, tree, _ = calculate(samples[index - 1], sample)
                except SamplerError:
                    tree = float("nan")
            stream.write(f"{index}\t{sample[0]}\t{sample[1]}\t{gap:.6f}\t{tree:.2f}\t{len(sample[2])}\n")
    with (output / "cpu.tsv").open("w") as stream:
        stream.write("index\tbeginMonotonicNS\tendMonotonicNS\tpid\tppid\tpgid\tstartSeconds\tstartMicroseconds\tcpuAbsoluteTicks\tcommand\n")
        for index, (begin, end, observations) in enumerate(samples):
            for (pid, sec, usec), (ppid, pgid, comm, cpu) in sorted(observations.items()):
                stream.write(f"{index}\t{begin}\t{end}\t{pid}\t{ppid}\t{pgid}\t{sec}\t{usec}\t{cpu}\t{comm}\n")
    (output / "timing.json").write_text(json.dumps({
        "startUTC": started_utc, "endUTC": datetime.now(timezone.utc).isoformat(),
        "runtimeSeconds": round((end_ns - launch_ns) / 1e9, 6), "exitCode": exit_code,
    }, indent=2) + "\n")
    (output / "cpu-summary.json").write_text(json.dumps({
        "snapshots": len(samples), "pidSamples": sum(len(s[2]) for s in samples),
        "helperSnapshots": helper_samples, "maximumConservativeGapSeconds": round(max_gap / 1e9, 6),
        "launchToFirstSampleSeconds": round((samples[0][1] - launch_ns) / 1e9, 6) if samples else None,
        "lastSampleToExitSeconds": round((end_ns - samples[-1][0]) / 1e9, 6) if samples else None,
        "maximumPIDCPUPercent": round(max_pid, 2),
        "maximumWholeTreeCPUPercent": round(max_tree, 2), "errors": errors,
    }, indent=2) + "\n")
    record = output / ("ww-018-calibration.jsonl" if mode == "calibration" else "ww-018-holdout-4.jsonl")
    log = (output / "run.log").read_text()
    if errors:
        verdict = ("FAIL: " if cpu_failure else "INCOMPLETE: ") + "; ".join(errors)
    elif exit_code or not record.exists() or f"Test {test_name}() passed" not in log:
        verdict = f"FAIL: test exit={exit_code}, records={record.exists()}, expected test passed={f'Test {test_name}() passed' in log}"
    elif len(record.read_bytes().splitlines()) != (466 if mode == "calibration" else 1370):
        verdict = "FAIL: record count differs from frozen calibration/holdout count"
    else:
        verdict = "PASS: objective test, record count, whole-tree CPU <400% and <=1s sampling coverage"
    (output / "verdict.txt").write_text(verdict + "\n")
    print(f"{mode}: {verdict} ({output})")
    if not verdict.startswith("PASS"):
        raise SamplerError(verdict)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("self-test", "probe", "calibration", "holdout"))
    parser.add_argument("output", nargs="?", type=Path)
    args = parser.parse_args()
    if args.mode == "self-test":
        self_test()
    elif args.mode == "probe":
        sampler = ProcessSampler()
        with subprocess.Popen(["sleep", "1"], start_new_session=True) as child:
            begin, end, observations = sampler.snapshot(os.getpid())
            if not any(k[0] == os.getpid() for k in observations):
                raise SamplerError("own PID missing from libproc snapshot")
            if not any(k[0] == child.pid and row[1] == child.pid
                       for k, row in observations.items()):
                raise SamplerError("child in a separate process group missing from ancestry snapshot")
            print(f"libproc ancestry + CPU counters: {(end - begin) / 1e9:.6f}s; separate-PGID child={child.pid}; BSDInfo={ctypes.sizeof(BSDInfo)} TaskInfo={ctypes.sizeof(TaskInfo)}")
    else:
        if args.output is None:
            parser.error("calibration and holdout require a new outside-repo evidence directory")
        run(args.mode, args.output)


if __name__ == "__main__":
    try:
        main()
    except (SamplerError, subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f"render CPU sampler: {error}", file=sys.stderr)
        sys.exit(2)
