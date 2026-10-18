#!/usr/bin/env python3
"""Prepare/score bounded, licensed AMI chunk-boundary controls. No private inputs."""
import argparse
import json
import math
import wave
from pathlib import Path
from zipfile import ZipFile

from benchmark import ANNOTATIONS, AUDIO, PUBLIC_INPUTS, alignment, checked_file, normalized, read_words, text_metrics


def prepare(root):
    for name in (ANNOTATIONS, AUDIO):
        checked_file(root / "downloads" / name, PUBLIC_INPUTS[name][1])
    with ZipFile(root / "downloads" / ANNOTATIONS) as archive:
        words = read_words(archive, "B")
    directory = root / "chunking"
    directory.mkdir(exist_ok=True)
    clips = []
    # Extend the previously selected public intervals, independently of recognizer output.
    for index, (start, end) in enumerate(((55.73, 165.91), (394.62, 487.21))):
        if any(word["start"] < end and word["end"] > start
               and not (word["start"] >= start and word["end"] <= end) for word in words):
            raise ValueError("The public excerpt boundary crosses a reference word")
        clips.append({
            "id": f"ami-long-{index + 1}", "source": f"downloads/{AUDIO}",
            "source_sha256": PUBLIC_INPUTS[AUDIO][1],
            "start": start, "end": end,
            "words": [dict(word, start=word["start"] - start, end=word["end"] - start)
                      for word in words if word["start"] >= start and word["end"] <= end],
        })
    with wave.open(str(root / "downloads" / AUDIO), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):
            raise ValueError("Expected the verified mono PCM16/16kHz source")
    (directory / "manifest.json").write_text(json.dumps({
        "attribution": "AMI Consortium / University of Edinburgh, CC BY 4.0",
        "timing_reference": "Automatically forced-aligned, not human-validated cut boundaries",
        "clips": clips,
    }, indent=2) + "\n")


def percentile(values):
    return sorted(values)[math.ceil(len(values) * .95) - 1] if values else None


def timing_matches(clip, actual):
    refs = [(token, word) for word in clip["words"] for token in normalized(word["text"])]
    hypotheses = [(token, segment) for segment in actual["segments"] for token in normalized(segment["text"])]
    matches = {}
    for kind, i, j in alignment([x[0] for x in refs], [x[0] for x in hypotheses]):
        if kind != "equal":
            continue
        token, segment = hypotheses[j]
        if len(normalized(segment["text"])) != 1 or segment.get("start") is None or segment.get("end") is None:
            continue
        word = refs[i][1]
        matches[i] = (token, segment["start"] - word["start"], segment["end"] - word["end"])
    return matches


def common_timing(root, manifest):
    comparisons = []
    for weights in ("baseEnglish", "turbo"):
        paths = [root / "chunking" / f"outputs-{weights}-{policy}.json" for policy in ("fixed", "pause")]
        if not all(path.exists() for path in paths):
            continue
        fixed, pause = [json.loads(path.read_text()) for path in paths]
        errors, onsets, offsets, signed = [[], []], [[], []], [[], []], [[], []]
        for clip, a, b in zip(manifest["clips"], fixed["clips"], pause["clips"], strict=True):
            matches = [timing_matches(clip, output) for output in (a, b)]
            for index in matches[0].keys() & matches[1].keys():
                for policy in range(2):
                    token, onset, offset = matches[policy][index]
                    errors[policy].extend((abs(onset), abs(offset)))
                    if token in ("um", "uh"):
                        onsets[policy].append(abs(onset))
                        offsets[policy].append(abs(offset))
                        signed[policy].append(onset)
        for policy, mode in enumerate(("fixed", "pause")):
            comparisons.append({
                "weights": weights, "mode": mode, "common_boundaries": len(errors[policy]),
                "boundary_p95": percentile(errors[policy]), "common_fillers": len(onsets[policy]),
                "filler_onset_p95": percentile(onsets[policy]), "filler_offset_p95": percentile(offsets[policy]),
                "filler_mean_signed_onset": sum(signed[policy]) / len(signed[policy]) if signed[policy] else None,
            })
    return comparisons


def score(root):
    manifest = json.loads((root / "chunking/manifest.json").read_text())
    summaries = []
    for path in sorted((root / "chunking").glob("outputs-*.json")):
        output = json.loads(path.read_text())
        totals = {key: 0 for key in ("reference_words", "sub", "del", "ins",
                                    "reference_fillers", "hypothesis_fillers", "matched_fillers")}
        all_errors, edge_errors, interior_errors, filler_onsets, filler_offsets = [], [], [], [], []
        signed_onsets = []
        edge_counts = {"reference_words": 0, "del": 0, "ins": 0}
        rendered_seconds = detection = wall = 0
        for clip, actual in zip(manifest["clips"], output["clips"], strict=True):
            refs = [(token, word) for word in clip["words"] for token in normalized(word["text"])]
            hypotheses = [(token, segment) for segment in actual["segments"]
                          for token in normalized(segment["text"])]
            reference = [item[0] for item in refs]
            hypothesis = [item[0] for item in hypotheses]
            result = text_metrics(reference, hypothesis)
            for key in totals:
                totals[key] += result[key]
            boundaries = [window["core"][1] / 48000 for window in actual["windows"][:-1]]
            near = lambda a, b: any(abs((a + b) / 2 - edge) <= 1 for edge in boundaries)
            edge_counts["reference_words"] += sum(near(w["start"], w["end"]) for _, w in refs)
            for kind, i, j in alignment(reference, hypothesis):
                if kind == "del" and near(refs[i][1]["start"], refs[i][1]["end"]):
                    edge_counts["del"] += 1
                if kind == "ins":
                    segment = hypotheses[j][1]
                    if segment.get("start") is not None and segment.get("end") is not None and near(segment["start"], segment["end"]):
                        edge_counts["ins"] += 1
                if kind != "equal":
                    continue
                token, segment = hypotheses[j]
                if len(normalized(segment["text"])) != 1 or segment.get("start") is None or segment.get("end") is None:
                    continue
                word = refs[i][1]
                onset, offset = segment["start"] - word["start"], segment["end"] - word["end"]
                all_errors.extend((abs(onset), abs(offset)))
                (edge_errors if near(word["start"], word["end"]) else interior_errors).extend((abs(onset), abs(offset)))
                if token in ("um", "uh"):
                    filler_onsets.append(abs(onset))
                    filler_offsets.append(abs(offset))
                    signed_onsets.append(onset)
            rendered_seconds += sum((w["candidate"][1] - w["candidate"][0]) / 48000 for w in actual["windows"])
            detection += actual["planning_seconds"]
            wall += actual["wall_seconds"]
        totals.update({
            "wer": (totals["sub"] + totals["del"] + totals["ins"]) / totals["reference_words"],
            "timing_boundaries": len(all_errors), "boundary_p95": percentile(all_errors),
            "edge_p95": percentile(edge_errors), "interior_p95": percentile(interior_errors),
            "filler_onset_p95": percentile(filler_onsets), "filler_offset_p95": percentile(filler_offsets),
            "filler_onset_mean_signed": sum(signed_onsets) / len(signed_onsets) if signed_onsets else None,
            "timed_fillers": len(filler_onsets), "edge_counts": edge_counts,
            "candidate_rendered_seconds": rendered_seconds, "planning_seconds": detection, "wall_seconds": wall,
            "variant": path.stem,
        })
        summaries.append(totals)
    (root / "chunking/summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
    (root / "chunking/timing-common.json").write_text(json.dumps(common_timing(root, manifest), indent=2) + "\n")
    print(json.dumps(summaries, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "score"))
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    root = args.artifacts.resolve()
    if root.is_relative_to(Path(__file__).resolve().parents[2]):
        parser.error("Keep audio, models, and raw output outside the repository")
    (prepare if args.action == "prepare" else score)(root)
