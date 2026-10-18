#!/usr/bin/env python3
"""Public AMI/Whisper pilot. No app integration, private inputs, or uploads."""

import argparse
import hashlib
import json
import math
import re
import shutil
import subprocess
import time
import urllib.request
import wave
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile


MODEL_REVISION = "5359861c739e955e79d9a303bcbc70fb988958b1"
MODELS = {
    "tiny.en": "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
    "base.en": "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
    "large-v3-turbo-q5_0": "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
}
ANNOTATIONS = "ami_public_manual_1.6.2.zip"
AUDIO = "ES2002a.Headset-1.wav"
PUBLIC_INPUTS = {
    ANNOTATIONS: (
        f"https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/{ANNOTATIONS}",
        "b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d",
    ),
    AUDIO: (
        f"https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2002a/audio/{AUDIO}",
        "285ed5b5eaa4f871cc146900d0cf87487ca757aa57a7062def2eb49feaabc23d",
    ),
}
# Selected from reference annotations before inference; no selection on model output.
WINDOWS = [
    (55.73, 67.55),
    (92.48, 102.00),
    (108.71, 132.20),
    (142.66, 165.91),
    (394.62, 422.47),
    (465.51, 487.21),
]
FILLERS = {"uh", "um"}
NITE_ID = "{http://nite.sourceforge.net/}id"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def checked_file(path, expected):
    actual = digest(path)
    if actual != expected:
        raise ValueError(f"SHA256 mismatch for {path.name}: {actual} != {expected}")


def normalized(text):
    # Preserve fillers, repetitions, fragments, numbers and British spellings.
    text = text.replace("[BLANK_AUDIO]", "")
    return re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)*", text.lower().replace("\u2019", "'"))


def alignment(reference, hypothesis):
    """Unit-cost Levenshtein; deterministic diagonal/deletion/insertion tie order."""
    rows, cols = len(reference) + 1, len(hypothesis) + 1
    costs = [[0] * cols for _ in range(rows)]
    for i in range(rows):
        costs[i][0] = i
    for j in range(cols):
        costs[0][j] = j
    for i in range(1, rows):
        for j in range(1, cols):
            costs[i][j] = min(
                costs[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]),
                costs[i - 1][j] + 1,
                costs[i][j - 1] + 1,
            )
    steps = []
    i, j = len(reference), len(hypothesis)
    while i or j:
        if i and j and costs[i][j] == costs[i - 1][j - 1] + (
            reference[i - 1] != hypothesis[j - 1]
        ):
            steps.append(("equal" if reference[i - 1] == hypothesis[j - 1] else "sub", i - 1, j - 1))
            i, j = i - 1, j - 1
        elif i and costs[i][j] == costs[i - 1][j] + 1:
            steps.append(("del", i - 1, None))
            i -= 1
        else:
            steps.append(("ins", None, j - 1))
            j -= 1
    return list(reversed(steps))


def text_metrics(reference, hypothesis):
    steps = alignment(reference, hypothesis)
    counts = {kind: sum(s[0] == kind for s in steps) for kind in ("equal", "sub", "del", "ins")}
    filler_total = sum(word in FILLERS for word in reference)
    hypothesis_fillers = sum(word in FILLERS for word in hypothesis)
    filler_matches = sum(
        kind == "equal" and reference[i] in FILLERS
        for kind, i, _ in steps if i is not None
    )
    return {
        "reference_words": len(reference),
        "hypothesis_words": len(hypothesis),
        **counts,
        "wer": (counts["sub"] + counts["del"] + counts["ins"]) / len(reference) if reference else None,
        "reference_fillers": filler_total,
        "hypothesis_fillers": hypothesis_fillers,
        "matched_fillers": filler_matches,
        "filler_recall": filler_matches / filler_total if filler_total else None,
        "filler_precision": filler_matches / hypothesis_fillers if hypothesis_fillers else None,
    }


def read_words(archive, speaker):
    root = ET.fromstring(archive.read(f"words/ES2002a.{speaker}.words.xml"))
    return [
        {
            "id": node.attrib[NITE_ID],
            "text": node.text or "",
            "start": float(node.attrib["starttime"]),
            "end": float(node.attrib["endtime"]),
        }
        for node in root
        if node.tag == "w" and node.attrib.get("punc") != "true"
    ]


def prepare(root):
    downloads, clips = root / "downloads", root / "clips"
    downloads.mkdir(parents=True, exist_ok=True)
    clips.mkdir(exist_ok=True)
    for name, (url, expected) in PUBLIC_INPUTS.items():
        path = downloads / name
        if not path.exists():
            temporary = path.with_suffix(path.suffix + ".partial")
            urllib.request.urlretrieve(url, temporary)
            checked_file(temporary, expected)
            temporary.rename(path)
        checked_file(path, expected)
    with ZipFile(downloads / ANNOTATIONS) as archive:
        words = read_words(archive, "B")
        others = [word for speaker in "ACD" for word in read_words(archive, speaker)]
    entries = []
    with wave.open(str(downloads / AUDIO), "rb") as source:
        if (source.getframerate(), source.getnchannels(), source.getsampwidth()) != (16000, 1, 2):
            raise ValueError("Expected 16kHz mono PCM16 AMI headset")
        for index, (start, end) in enumerate(WINDOWS):
            first, last = round(start * 16000), round(end * 16000)
            selected = [w for w in words if w["start"] >= start and w["end"] <= end]
            crossing = [w for w in words if w["start"] < end and w["end"] > start and w not in selected]
            if crossing:
                raise ValueError(f"Window {index} clips reference words: {crossing}")
            name = f"ami-{index + 1:02d}"
            source.setpos(first)
            samples = source.readframes(last - first)
            if len(samples) != (last - first) * 2:
                raise ValueError("Short audio read")
            path = clips / f"{name}.wav"
            with wave.open(str(path), "wb") as out:
                out.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                out.writeframes(samples)
            entries.append({
                "id": name, "audio": f"clips/{name}.wav", "audio_sha256": digest(path),
                "source_start_frame": first, "source_end_frame": last,
                "duration_seconds": (last - first) / 16000,
                "words": selected,
                "other_speaker_reference_words": [
                    w for w in others if w["start"] < end and w["end"] > start
                ],
            })
    path = clips / "silence.wav"
    with wave.open(str(path), "wb") as out:
        out.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        out.writeframes(bytes(10 * 16000 * 2))
    entries.append({
        "id": "silence", "audio": "clips/silence.wav", "audio_sha256": digest(path),
        "duration_seconds": 10, "source_start_frame": 0, "source_end_frame": 160000,
        "words": [], "other_speaker_reference_words": [],
    })
    manifest = {
        "dataset": "AMI ES2002a, speaker B, headset channel 1, manual annotations 1.6.2",
        "license": "CC-BY-4.0",
        "attribution": "AMI Meeting Corpus, University of Edinburgh / AMI Consortium",
        "source": "https://groups.inf.ed.ac.uk/ami/corpus/",
        "timing_reference": "Automatically forced-aligned, NOT hand-validated cut boundaries",
        "public_inputs": {name: {"url": url, "sha256": sha} for name, (url, sha) in PUBLIC_INPUTS.items()},
        "clips": entries,
    }
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for clip in entries:
        print(clip["id"], clip["duration_seconds"], len(normalized(" ".join(w["text"] for w in clip["words"]))),
              "other-speaker words:", len(clip["other_speaker_reference_words"]))


def run(root, model, cli, prompted):
    executable = shutil.which(cli)
    if executable is None:
        raise FileNotFoundError(f"ASR executable unavailable: {cli}")
    version_output = subprocess.run([executable, "--version"], capture_output=True, text=True, check=True)
    versions = [line for line in (version_output.stdout + version_output.stderr).splitlines()
                if line.startswith("whisper.cpp version:")]
    if len(versions) != 1:
        raise ValueError("Expected a whisper.cpp CLI with a reported version")
    model_path = root / "downloads" / f"ggml-{model}.bin"
    checked_file(model_path, MODELS[model])
    manifest = json.loads((root / "manifest.json").read_text())
    variant = model + ("-prompted" if prompted else "")
    out_dir = root / "runs" / variant
    out_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for clip in manifest["clips"]:
        audio = root / clip["audio"]
        checked_file(audio, clip["audio_sha256"])
        prefix = out_dir / clip["id"]
        command = [
            executable, "-m", str(model_path), "-f", str(audio), "-l", "en", "-t", "4", "-p", "1",
            "-bs", "5", "-bo", "5", "-tp", "0", "-tpi", "0", "-nf",
            "-ojf", "-otxt", "-of", str(prefix), "-ml", "1", "-sow",
        ]
        if prompted:
            command += ["--prompt", "Um, uh, well, I, I mean, you know, like, sort of."]
        # macOS time -l: per-process peak RSS, not total shared GPU/ANE allocation.
        started = time.perf_counter()
        with prefix.with_suffix(".stdout").open("w") as stdout, prefix.with_suffix(".stderr").open("w") as stderr:
            subprocess.run(["/usr/bin/time", "-l", *command], stdout=stdout, stderr=stderr, check=True)
        elapsed = time.perf_counter() - started
        log = prefix.with_suffix(".stderr").read_text()
        rss = re.search(r"(\d+)\s+maximum resident set size", log)
        results.append({
            "clip": clip["id"], "wall_seconds": elapsed,
            "peak_process_rss_bytes": int(rss.group(1)) if rss else None,
            "command": [Path(part).name if part.startswith("/") else part for part in command],
            "audio_sha256": clip["audio_sha256"],
        })
        print(variant, clip["id"], round(elapsed, 3), "seconds", flush=True)
    (out_dir / "measurements.json").write_text(json.dumps({
        "model": model, "model_revision": MODEL_REVISION, "model_sha256": MODELS[model],
        "runtime": versions[0], "executable_sha256": digest(Path(executable)),
        "prompted": prompted, "runs": results,
    }, indent=2) + "\n")


def score(root, variant):
    manifest = json.loads((root / "manifest.json").read_text())
    out_dir = root / "runs" / variant
    measurements = json.loads((out_dir / "measurements.json").read_text())
    clips = []
    for clip, measurement in zip(manifest["clips"], measurements["runs"], strict=True):
        if clip["id"] != measurement["clip"]:
            raise ValueError("Measurement/manifest identity mismatch")
        checked_file(root / clip["audio"], clip["audio_sha256"])
        reference = normalized(" ".join(w["text"] for w in clip["words"]))
        text = (out_dir / f'{clip["id"]}.txt').read_text().strip()
        hypothesis = normalized(text)
        metrics = text_metrics(reference, hypothesis)
        # -ml 1 -sow emits approximate word segments; no interpolation to claim timing.
        output = json.loads((out_dir / f'{clip["id"]}.json').read_text())
        timed_words = []
        for segment in output["transcription"]:
            tokens = normalized(segment["text"])
            for token in tokens:
                interval = (segment["offsets"]["from"] / 1000, segment["offsets"]["to"] / 1000)
                timed_words.append((token, interval if len(tokens) == 1 else None))
        if [w[0] for w in timed_words] != hypothesis:
            raise ValueError("JSON word sequence disagrees with text output")
        reference_tokens = [(token, word) for word in clip["words"] for token in normalized(word["text"])]
        timing_errors = []
        start = clip["source_start_frame"] / 16000
        for kind, i, j in alignment([w[0] for w in reference_tokens], [w[0] for w in timed_words]):
            if kind == "equal":
                word = reference_tokens[i][1]
                interval = timed_words[j][1]
                if interval and 0 <= interval[0] < interval[1] <= clip["duration_seconds"]:
                    timing_errors.extend([1000 * abs(interval[0] - (word["start"] - start)),
                                          1000 * abs(interval[1] - (word["end"] - start))])
        clips.append({
            "id": clip["id"], "duration_seconds": clip["duration_seconds"],
            "source_start_frame": clip["source_start_frame"], "source_end_frame": clip["source_end_frame"],
            "audio_sha256": clip["audio_sha256"], "other_speaker_words": len(clip["other_speaker_reference_words"]),
            **metrics, **{key: measurement[key] for key in ("wall_seconds", "peak_process_rss_bytes")},
            "reference_text": " ".join(w["text"] for w in clip["words"]), "hypothesis_text": text,
            "non_speech_labels": ["BLANK_AUDIO"] if "[BLANK_AUDIO]" in text else [],
            "timing_proxy": {
                "reference_boundaries": 2 * len(reference_tokens), "matched_boundaries": len(timing_errors),
                "p95_absolute_ms": sorted(timing_errors)[math.ceil(0.95 * len(timing_errors)) - 1] if timing_errors else None,
                "maximum_absolute_ms": max(timing_errors) if timing_errors else None,
                "qualification": "Raw ASR word-segment vs forced-alignment proxy only; not cut accuracy",
            },
        })
    speech = [c for c in clips if c["id"] != "silence"]
    totals = {key: sum(c[key] for c in speech) for key in
              ("reference_words", "hypothesis_words", "sub", "del", "ins", "reference_fillers", "hypothesis_fillers", "matched_fillers",
               "duration_seconds", "wall_seconds")}
    totals["wer"] = (totals["sub"] + totals["del"] + totals["ins"]) / totals["reference_words"]
    totals["filler_recall"] = totals["matched_fillers"] / totals["reference_fillers"]
    totals["filler_precision"] = totals["matched_fillers"] / totals["hypothesis_fillers"] if totals["hypothesis_fillers"] else None
    totals["realtime_factor"] = totals["wall_seconds"] / totals["duration_seconds"]
    totals["max_process_rss_bytes"] = max(c["peak_process_rss_bytes"] for c in clips)
    result = {
        "variant": variant, "model_revision": measurements["model_revision"],
        "model_sha256": measurements["model_sha256"],
        "runtime": measurements["runtime"], "executable_sha256": measurements["executable_sha256"],
        "normalization": "Exclude [BLANK_AUDIO] non-speech label; lowercase ASCII alphanumerics with internal apostrophes; punctuation/hyphens split; no filler/repetition removal, number expansion, spelling aliases or contraction expansion.",
        "aggregate_speech": totals, "clips": clips,
    }
    (out_dir / "scores.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"variant": variant, **totals}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "run", "score"))
    parser.add_argument("--artifacts", required=True, type=Path, help="External local artifact directory, not the repo")
    parser.add_argument("--model", choices=MODELS, default="base.en")
    parser.add_argument("--cli", default="whisper-cli")
    parser.add_argument("--prompted", action="store_true")
    args = parser.parse_args()
    root = args.artifacts.resolve()
    if root.is_relative_to(Path(__file__).resolve().parents[2]):
        parser.error("Keep downloaded audio/models/outputs outside this repository")
    if args.action == "prepare":
        prepare(root)
    elif args.action == "run":
        run(root, args.model, args.cli, args.prompted)
    else:
        score(root, args.model + ("-prompted" if args.prompted else ""))


if __name__ == "__main__":
    main()
