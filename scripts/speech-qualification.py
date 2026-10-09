#!/usr/bin/env python3
"""Synthetic-only, locally sandboxed WW-026 speech candidate qualification."""

import argparse
import hashlib
import json
import os
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODEL_SHA256 = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
MODEL_BYTES = 147_964_211
MODEL_SOURCE = (
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/"
    "5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin"
)
RUNTIME_VERSION = "1.9.4"
RUNTIME_SHA256 = "13650fc8ffaaa4e637c6951f7d2e492916877e70bd1b7a266fbfd0bdc597719e"
SANDBOX = "/usr/bin/sandbox-exec"
PROFILE = "(version 1)(allow default)(deny network*)"
CASES = (
    "The silver lantern is beside the quiet river.",
    "Please move the blue folder before the meeting begins.",
)
TIMEOUT_SECONDS = 180


class QualificationError(Exception):
    pass


def _group_alive(process):
    process.poll()
    try:
        os.killpg(process.pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # macOS may report EPERM for zombies; wait for the group to disappear.
        return True
    return True


def _stop_group(process):
    def wait_for_exit(seconds):
        deadline = time.monotonic() + seconds
        while _group_alive(process):
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.01)
        return True

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    if not wait_for_exit(1):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            # Zombie-only groups cannot be signaled; the bounded wait must still see ESRCH.
            pass
        if not wait_for_exit(2):
            raise QualificationError("command process group survived SIGKILL; temporary inputs are unsafe to remove")
    process.communicate(timeout=2)


def run(argv, *, timeout=TIMEOUT_SECONDS):
    try:
        process = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
    except OSError as error:
        raise QualificationError(f"command unavailable or timed out: {Path(argv[0]).name}") from error
    with process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt, OSError) as error:
            _stop_group(process)
            if isinstance(error, KeyboardInterrupt):
                raise
            if isinstance(error, OSError):
                raise QualificationError(f"command I/O failed: {Path(argv[0]).name}") from error
            raise QualificationError(f"command unavailable or timed out: {Path(argv[0]).name}") from error
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def guarded(argv, *, timeout=TIMEOUT_SECONDS):
    return run([SANDBOX, "-p", PROFILE, *map(str, argv)], timeout=timeout)


def no_egress_control():
    for action in (
        "s.bind(('127.0.0.1',0))",
        "s.connect(('127.0.0.1',9))",
    ):
        probe = guarded(
            [sys.executable, "-c", f"import socket; s=socket.socket(socket.AF_INET,socket.SOCK_STREAM); {action}"]
        )
        if probe.returncode == 0:
            raise QualificationError("network-denial control unexpectedly allowed a local IP operation")
        if "operation not permitted" not in probe.stderr.lower():
            raise QualificationError("network-denial control failed for a reason other than sandbox denial")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as body:
        for block in iter(lambda: body.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inspect_model(path):
    path = path.resolve(strict=True)
    if path.is_relative_to(ROOT) or not path.is_file():
        raise QualificationError("model must be a regular file outside the repository")
    if path.stat().st_size != MODEL_BYTES or sha256(path) != MODEL_SHA256:
        raise QualificationError("model size or SHA-256 differs from the pinned official-source artifact")
    return {
        "name": "ggml-base.en.bin",
        "version": "ggerganov/whisper.cpp@5359861c739e955e79d9a303bcbc70fb988958b1",
        "bytes": MODEL_BYTES,
        "sha256": MODEL_SHA256,
        "source": MODEL_SOURCE,
        "license": "MIT upstream code/weights claim; conversion and redistribution not cleared",
        "tokenizer": "embedded in this ggml model; no separate tokenizer or Hub loader",
    }


def words(text):
    return re.findall(r"[a-z0-9']+", text.lower())


def word_error_rate(expected, actual):
    reference, observed = words(expected), words(actual)
    previous = list(range(len(observed) + 1))
    for i, token in enumerate(reference, 1):
        current = [i]
        for j, candidate in enumerate(observed, 1):
            current.append(
                min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (token != candidate))
            )
        previous = current
    return previous[-1] / len(reference)


def check_runtime(executable):
    executable = executable.resolve(strict=True)
    if executable.is_relative_to(ROOT) or not executable.is_file():
        raise QualificationError("whisper-cli must be a file outside the repository")
    version = guarded([executable, "--version"], timeout=30)
    if version.returncode or not re.search(
        rf"(?m)^whisper\.cpp version: {re.escape(RUNTIME_VERSION)}\s*$",
        version.stdout + version.stderr,
    ):
        raise QualificationError(f"whisper-cli is not the pinned {RUNTIME_VERSION} runtime")
    executable_hash = sha256(executable)
    if executable_hash != RUNTIME_SHA256:
        raise QualificationError("whisper-cli SHA-256 differs from the measured installed runtime")
    return {
        "name": "whisper.cpp",
        "version": RUNTIME_VERSION,
        "executableSHA256": executable_hash,
        "source": f"https://github.com/ggml-org/whisper.cpp/releases/tag/v{RUNTIME_VERSION}",
        "license": "MIT; installed Homebrew build and linked ggml/Apple dependencies, not a redistribution BOM",
    }


def boot_epoch():
    result = run(["/usr/sbin/sysctl", "-n", "kern.boottime"], timeout=10)
    match = re.search(r"\bsec = (\d+)\b", result.stdout)
    if result.returncode or match is None:
        raise QualificationError("boot session could not be identified")
    return int(match.group(1))


def create_pcm(text, directory, index):
    aiff = directory / f"case-{index}.aiff"
    wav = directory / f"case-{index}.wav"
    synthesis = guarded(["/usr/bin/say", "-v", "Samantha", "-o", aiff, text])
    if synthesis.returncode:
        raise QualificationError("offline synthetic voice generation failed (voice may not be installed)")
    conversion = guarded(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav])
    if conversion.returncode:
        raise QualificationError("offline synthetic PCM conversion failed")
    with wave.open(str(wav), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
            raise QualificationError("synthetic input is not 16 kHz mono 16-bit PCM")
        duration = audio.getnframes() / audio.getframerate()
    if duration <= 0:
        raise QualificationError("synthetic input contains no frames")
    return wav, duration


def parse_whisper(path):
    try:
        data = json.loads(path.read_text())
        segments = data["transcription"]
        transcript = " ".join(segment["text"] for segment in segments)
        timing = sum(
            isinstance(segment.get("offsets", {}).get("from"), int)
            and isinstance(segment.get("offsets", {}).get("to"), int)
            and segment["offsets"]["to"] > segment["offsets"]["from"]
            for segment in segments
        )
    except (OSError, KeyError, TypeError, ValueError) as error:
        raise QualificationError("whisper output is absent or malformed") from error
    if not words(transcript):
        raise QualificationError("whisper returned no English words for synthetic speech")
    return transcript, {"timedSegments": timing, "segments": len(segments)}


def peak_rss(stderr):
    match = re.search(r"^\s*(\d+)\s+maximum resident set size\s*$", stderr, re.MULTILINE)
    if match is None:
        raise QualificationError("resource observer did not report maximum resident set size")
    return int(match.group(1))


def observe_whisper(executable, model, wav, duration, directory, index, expected):
    output = directory / f"whisper-{index}"
    started = time.monotonic()
    result = run(
        [
            "/usr/bin/time", "-l", SANDBOX, "-p", PROFILE, str(executable),
            "-m", str(model), "-f", str(wav), "-l", "en", "-t", "4", "-p", "1",
            "-oj", "-of", str(output), "-np",
        ]
    )
    elapsed = time.monotonic() - started
    if result.returncode:
        raise QualificationError(f"whisper inference failed (exit {result.returncode}); no transcript retained")
    transcript, timing = parse_whisper(output.with_suffix(".json"))
    return {
        "durationSeconds": round(duration, 3),
        "wallSeconds": round(elapsed, 3),
        "rtf": round(elapsed / duration, 3),
        "observedProcessPeakRSSBytes": peak_rss(result.stderr),
        "wordErrorRate": round(word_error_rate(expected, transcript), 3),
        "recognizedWords": len(words(transcript)),
        "segmentTiming": timing,
        "network": "DENIED for inference process by validated sandbox; system-level egress unobserved",
    }


def inspect_native(binary):
    if binary is None:
        return {"availability": "UNKNOWN", "reason": "native probe not supplied"}
    binary = binary.resolve(strict=True)
    if binary.is_relative_to(ROOT) or not binary.is_file():
        raise QualificationError("native probe must be a file outside the repository")
    result = guarded([binary, "--availability"], timeout=30)
    if result.returncode:
        raise QualificationError("native availability probe failed (asset status cannot be assumed)")
    try:
        data = json.loads(result.stdout)
    except ValueError as error:
        raise QualificationError("native availability probe did not return JSON") from error
    if data.get("availability") not in ("installed", "supportedOnly", "unsupported"):
        raise QualificationError("native availability probe returned an unknown status")
    data["probeSHA256"] = sha256(binary)
    return data


def qualify(args):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise QualificationError("requires Apple silicon macOS")
    no_egress_control()
    model_path = args.model.resolve(strict=True)
    runtime_path = args.whisper_cli.resolve(strict=True)
    model = inspect_model(model_path)
    runtime = check_runtime(runtime_path)
    native = inspect_native(args.native_probe)
    cases = []
    with tempfile.TemporaryDirectory(prefix="ww-synthetic-speech-") as temporary:
        directory = Path(temporary).resolve()
        if directory.is_relative_to(ROOT):
            raise QualificationError("synthetic input must stay outside the repository")
        for index, expected in enumerate(CASES, 1):
            wav, duration = create_pcm(expected, directory, index)
            entry = {"case": index, "input": "locally synthesized en-US PCM"}
            entry["whisper"] = observe_whisper(
                runtime_path, model_path, wav, duration, directory, index, expected
            )
            if native["availability"] == "installed":
                entry["native"] = {
                    "state": "BLOCKED",
                    "reason": "system Speech service no-egress instrumentation is unavailable",
                }
            else:
                entry["native"] = {"state": "NOT_RUN", "reason": native["availability"]}
            cases.append(entry)
    inspect_model(model_path)
    if sha256(runtime_path) != runtime["executableSHA256"]:
        raise QualificationError("runtime changed during synthetic inference")
    return {
        "gate": "synthetic calibration only; neither candidate adopted",
        "host": {
            "macOS": platform.mac_ver()[0],
            "architecture": platform.machine(),
            "bootEpochSeconds": boot_epoch(),
            "physicalRAMBytes": int(run(["/usr/sbin/sysctl", "-n", "hw.memsize"]).stdout.strip()),
        },
        "model": model,
        "runtime": runtime,
        "nativeAsset": native,
        "cases": cases,
        "unsupported": [
            "macOS 26, 16 GB, cold-restart, thermal, long-episode, and representative-audio strata UNKNOWN",
            "process-family and Speech service peak RAM UNKNOWN; observed RSS is only the timed process",
            "native asset hash/version/update and system Speech service network activity UNKNOWN",
            "Whisper word-level boundary accuracy and chosen-build redistribution rights UNKNOWN",
            "no private or episode media processed; synthetic recognition alone cannot select an engine",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True, help="pinned model file outside the repo")
    parser.add_argument("--whisper-cli", type=Path, required=True, help="installed whisper.cpp 1.9.4 CLI")
    parser.add_argument("--native-probe", type=Path, help="compiled speech-native-probe.swift outside the repo")
    args = parser.parse_args()
    try:
        print(json.dumps(qualify(args), indent=2, sort_keys=True))
    except (QualificationError, FileNotFoundError, PermissionError, ValueError) as error:
        print(f"qualification refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
