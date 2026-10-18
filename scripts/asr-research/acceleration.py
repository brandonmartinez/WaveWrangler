#!/usr/bin/env python3
"""Compare the exact vendored native recipe on hash-verified public AMI clips."""
import argparse
import array
import json
import math
import subprocess
import sys
import wave
from pathlib import Path

from benchmark import MODELS, alignment, checked_file, digest, normalized, text_metrics


def metrics(clips, outputs):
    totals = {key: 0 for key in ("reference_words", "sub", "del", "ins", "reference_fillers",
                               "hypothesis_fillers", "matched_fillers")}
    boundaries = []
    controls = []
    for clip, output in zip(clips, outputs, strict=True):
        reference = [token for word in clip["words"] for token in normalized(word["text"])]
        hypothesis = normalized(" ".join(s["text"] for s in output["segments"]))
        result = text_metrics(reference, hypothesis)
        if reference:
            for key in totals:
                totals[key] += result[key]
        else:
            controls.append({"clip": clip["id"], "emitted_words": len(hypothesis),
                             "text": " ".join(s["text"] for s in output["segments"])})
        timed = [(token, segment if len(normalized(segment["text"])) == 1 else None)
                 for segment in output["segments"] for token in normalized(segment["text"])]
        refs = [(token, word) for word in clip["words"] for token in normalized(word["text"])]
        origin = clip["source_start_frame"] / 16000
        for kind, i, j in alignment(reference, hypothesis):
            if kind != "equal":
                continue
            segment = timed[j][1]
            if (segment and segment.get("start") is not None and segment.get("end") is not None
                    and 0 <= segment["start"] < segment["end"] <= clip["duration_seconds"]):
                word = refs[i][1]
                boundaries += [abs(segment["start"] - (word["start"] - origin)),
                               abs(segment["end"] - (word["end"] - origin))]
    totals["wer"] = (totals["sub"] + totals["del"] + totals["ins"]) / totals["reference_words"]
    totals["timing_matched_boundaries"] = len(boundaries)
    totals["timing_proxy_p95_seconds"] = sorted(boundaries)[math.ceil(len(boundaries) * .95) - 1] if boundaries else None
    totals["empty_reference_controls"] = controls
    return totals


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--model", choices=("base.en", "large-v3-turbo-q5_0"), required=True)
    parser.add_argument("--backend", choices=("cpu", "metal"), required=True)
    parser.add_argument("--workers", type=int, choices=(1, 2, 4), default=1)
    parser.add_argument("--threads", type=int, choices=(1, 2, 4, 8), default=4)
    parser.add_argument("--coreml", action="store_true", help="Label a separately compiled Core ML executable")
    parser.add_argument("--cancel-ms", type=int, default=0)
    args = parser.parse_args()
    root = args.artifacts.resolve()
    if root.is_relative_to(Path(__file__).resolve().parents[2]):
        parser.error("Keep audio, weights and raw results outside the repository")
    model = root / "downloads" / f"ggml-{args.model}.bin"
    checked_file(model, MODELS[args.model])
    manifest = json.loads((root / "manifest.json").read_text())
    clips = manifest["clips"]
    inputs = []
    for clip in clips:
        wav = root / clip["audio"]
        checked_file(wav, clip["audio_sha256"])
        with wave.open(str(wav), "rb") as source:
            if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):
                raise ValueError("Expected mono PCM16/16kHz")
            samples = array.array("h", source.readframes(source.getnframes()))
            if sys.byteorder != "little":
                samples.byteswap()
        pcm = root / "clips" / (clip["id"] + ".f32")
        pcm.write_bytes(array.array("f", (s / 32768 for s in samples)).tobytes())
        inputs.append(str(pcm))
    variant = f"{args.model}-{args.backend}-{'coreml-' if args.coreml else ''}{args.workers}w-{args.threads}t"
    if args.cancel_ms:
        variant += "-cancel"
        inputs = inputs[:1]
    command = [str(args.executable.resolve()), str(model), args.backend, str(args.threads), str(args.workers),
               "2" if not args.cancel_ms else "1", str(args.cancel_ms), *inputs]
    directory = root / "acceleration"
    directory.mkdir(exist_ok=True)
    with (directory / f"{variant}.stderr").open("w") as stderr:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=stderr, check=True)
    output = json.loads(result.stdout)
    if not args.cancel_ms:
        for run in output["rounds"]:
            if any(clip["status"] != 0 for clip in run["clips"]):
                raise ValueError("Native inference failed")
            run["metrics"] = metrics(clips, run["clips"])
            run["audio_seconds"] = sum(c["duration_seconds"] for c in clips)
    output.update({"variant": variant, "model_sha256": MODELS[args.model],
                   "executable_sha256": digest(args.executable),
                   "clips": [{"id": c["id"], "audio_sha256": c["audio_sha256"]} for c in clips],
                   "command": command})
    (directory / f"{variant}.json").write_text(json.dumps(output, indent=2) + "\n")
    print(variant, json.dumps([{
        "wall_seconds": r["wall_seconds"], "peak_rss_bytes": r["peak_rss_bytes"],
        "wer": r.get("metrics", {}).get("wer"),
        "matched_fillers": r.get("metrics", {}).get("matched_fillers"),
        "inference_seconds": [c["inference_seconds"] for c in r["clips"]] if args.cancel_ms else None,
    } for r in output["rounds"]]), flush=True)


if __name__ == "__main__":
    main()
