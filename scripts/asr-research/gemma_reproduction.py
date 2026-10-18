#!/usr/bin/env python3
"""Independent john-rocky reader v2, NOT the eg2.haku.sh app. Public AMI inputs only."""

import argparse
import importlib.metadata
import json
import os
import resource
import sys
import subprocess
import time
import urllib.request
import wave
from pathlib import Path

from benchmark import checked_file, digest, normalized, text_metrics


BASE_REV = "914f7f89142e33e77833254d9c9b90c3cef7303b"
READER_REV = "de224fd8fa4ed4519fdddd9aa4154432d46a1bd3"
CODE_REV = "e6b7d5df02fcfe940c194d00ad5d055f958b9c6c"
BASE_URL = f"https://huggingface.co/google/embeddinggemma-2/resolve/{BASE_REV}"
READER_URL = f"https://huggingface.co/mlboydaisuke/EmbeddingGemma-2-Transcribe-Reader/resolve/{READER_REV}"
CODE_URL = f"https://raw.githubusercontent.com/john-rocky/eg2-transcribe/{CODE_REV}/reader/train"
ASSETS = {
    "base/model.safetensors": (BASE_URL, "197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79"),
    "base/config.json": (BASE_URL, "b8f1e9931b57fbc054acdb445c41765d55b0074c58d145fa82839941ad1b5bb3"),
    "base/preprocessor_config.json": (BASE_URL, "ea2ae257e901064abdd98dceb19f2b0da06af600bed15e0f99f5c85c37ee9d78"),
    "reader/reader.pt": (READER_URL, "d605f6fba8687497be6b5fd717ea6c51beaee5d5f69c30a64225da96ebe0d8c2"),
    "reader/word_table.npy": (READER_URL, "b2d0b13cc70c492f1444b8a42deab437d25254eac47d752d777d27b65377faa8"),
    "reader/vocab.txt": (READER_URL, "bb3b3c70379082333e1bbd90d07ca69fe5c0096bd1c3b2b3f83edd65f1062a68"),
    "reader/reader_config.json": (READER_URL, "3aede371f7fc1b69bd948a3fce6f861e44eedb237d7b6dce360063ea007a90ed"),
    "reader/LICENSE": (READER_URL, "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
    "reader/NOTICE": (READER_URL, "f353028c569417fff6bcd8c1e2ee8d77efe765c2ad2238ec36ff64be574cda2c"),
    "code/model.py": (CODE_URL, "d71d2bac4cf14f98f91029978c67ace2d940b6f01e1213350cfee330bfdbefe9"),
    "code/decode.py": (CODE_URL, "b447a21b5031f201ba60353e45c6cb13b32e97a9294f4c61728e1d8e29d35b2f"),
}


def prepare(root):
    for relative, (prefix, sha) in ASSETS.items():
        path = root / "gemma" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            temporary = path.with_suffix(path.suffix + ".partial")
            urllib.request.urlretrieve(f"{prefix}/{path.name}", temporary)
            checked_file(temporary, sha)
            temporary.rename(path)
        checked_file(path, sha)
        print(relative, "verified", flush=True)


def prepare_calibration(root):
    """One publisher audio/reference pair, separate from conversational scoring."""
    directory = root / "calibration"
    directory.mkdir(exist_ok=True)
    url = ("https://datasets-server.huggingface.co/rows?dataset=hf-internal-testing%2F"
           "librispeech_asr_dummy&config=clean&split=validation&offset=0&length=1")
    with urllib.request.urlopen(url, timeout=30) as response:
        data = json.load(response)
    row = data["rows"][0]["row"]
    reference = row["text"]
    if row["id"] != "1272-128104-0000" or reference != (
        "MISTER QUILTER IS THE APOSTLE OF THE MIDDLE CLASSES AND WE ARE GLAD TO WELCOME HIS GOSPEL"
    ):
        raise ValueError("Public calibration row changed")
    flac = directory / "1272-128104-0000.flac"
    if not flac.exists():
        with urllib.request.urlopen(row["audio"][0]["src"], timeout=30) as response:
            flac.write_bytes(response.read(256_000))
    checked_file(flac, "4e25e22555cd16e90edb0a3b49fdcf1fe652b2a1250ab643634db33895c75b41")
    (directory / "publisher-row.json").write_text(json.dumps(data, indent=2) + "\n")
    wav = directory / "clean-control.wav"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(flac),
                    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)], check=True)
    with wave.open(str(wav), "rb") as stream:
        duration = stream.getnframes() / stream.getframerate()
    manifest = {
        "dataset": "LibriSpeech dev-clean 1272-128104-0000; public reference via HF dummy subset",
        "license": "CC-BY-4.0", "source": url,
        "clips": [{
            "id": "clean-control", "audio": "calibration/clean-control.wav",
            "audio_sha256": digest(wav), "duration_seconds": duration,
            "words": [{"text": reference}],
        }],
    }
    (root / "calibration-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def run(root, calibration=False):
    for relative, (_, sha) in ASSETS.items():
        checked_file(root / "gemma" / relative, sha)
    # Fail closed to local files after the explicit separate download stage.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    initialized = time.perf_counter()
    import numpy as np
    import torch
    from transformers import EmbeddingGemma2Model, Gemma4AudioFeatureExtractor

    torch.set_num_threads(4)
    torch.set_num_interop_threads(1)
    sys.path.insert(0, str(root / "gemma" / "code"))
    from decode import load_reader_dir, transcribe_batch

    base = str(root / "gemma" / "base")
    extractor = Gemma4AudioFeatureExtractor.from_pretrained(base, local_files_only=True)
    encoder = EmbeddingGemma2Model.from_pretrained(
        base, dtype=torch.float32, vision_config=None, local_files_only=True
    ).eval()
    if encoder.config.audio_config._attn_implementation != "sdpa":
        raise ValueError("Require the upstream reference SDPA attention, not eager")
    reader, table, vocab, config = load_reader_dir(str(root / "gemma" / "reader"), "cpu")
    if config["version"] != "v2" or not {"uh", "um"}.issubset(vocab):
        raise ValueError("Unexpected reader release or missing filler vocabulary")
    load_seconds = time.perf_counter() - initialized
    manifest = json.loads((root / ("calibration-manifest.json" if calibration else "manifest.json")).read_text())
    output = root / "runs" / ("gemma-independent-v2-cpu" + ("-calibration" if calibration else ""))
    output.mkdir(parents=True, exist_ok=True)
    clips = []
    with torch.inference_mode():
        for clip in manifest["clips"]:
            audio = root / clip["audio"]
            checked_file(audio, clip["audio_sha256"])
            with wave.open(str(audio), "rb") as stream:
                if (stream.getframerate(), stream.getnchannels(), stream.getsampwidth()) != (16000, 1, 2):
                    raise ValueError("Expected public mono PCM16/16kHz benchmark WAV")
                wav = np.frombuffer(stream.readframes(stream.getnframes()), dtype="<i2").astype(np.float32) / 32768
            if len(wav) > 480_000:
                raise ValueError("This bounded reference runner supports at most 30 seconds per clip")
            started = time.perf_counter()
            features = extractor([wav], return_tensors="np")
            feats = features["input_features"][0].astype(np.float32)
            mask = features["input_features_mask"][0].astype(bool)
            result = encoder.get_audio_features(
                torch.from_numpy(feats)[None], torch.from_numpy(mask)[None], return_dict=True
            )
            tokens = result.pooler_output[0][result.attention_mask[0]].float().numpy()
            encoder_seconds = time.perf_counter() - started
            reader_started = time.perf_counter()
            text = transcribe_batch(reader, [tokens], table, vocab, "cpu")[0]
            reader_seconds = time.perf_counter() - reader_started
            reference = normalized(" ".join(w["text"] for w in clip["words"]))
            metrics = text_metrics(reference, normalized(text))
            entry = {
                "id": clip["id"], "audio_sha256": clip["audio_sha256"],
                "duration_seconds": clip["duration_seconds"], **metrics,
                "hypothesis_text": text, "encoder_seconds": encoder_seconds,
                "reader_seconds": reader_seconds, "wall_seconds": encoder_seconds + reader_seconds,
                "word_timing": None,
            }
            clips.append(entry)
            (output / f'{clip["id"]}.txt').write_text(text + "\n")
            print(clip["id"], round(entry["wall_seconds"], 3), text, flush=True)
    speech = [clip for clip in clips if clip["id"] != "silence"]
    totals = {
        key: sum(clip[key] for clip in speech)
        for key in ("reference_words", "hypothesis_words", "sub", "del", "ins", "reference_fillers",
                    "hypothesis_fillers", "matched_fillers", "duration_seconds", "wall_seconds")
    }
    totals["wer"] = (totals["sub"] + totals["del"] + totals["ins"]) / totals["reference_words"]
    totals["filler_recall"] = totals["matched_fillers"] / totals["reference_fillers"] if totals["reference_fillers"] else None
    totals["filler_precision"] = totals["matched_fillers"] / totals["hypothesis_fillers"] if totals["hypothesis_fillers"] else None
    record = {
        "engine": "Independent john-rocky reader v2; NOT eg2.haku.sh",
        "base_revision": BASE_REV, "reader_revision": READER_REV, "code_revision": CODE_REV,
        "device": "CPU float32, four intraop threads, one interop thread, SDPA, no LM/punctuation",
        "dependencies": {name: importlib.metadata.version(name) for name in ("numpy", "torch", "transformers")},
        "initialization_seconds": load_seconds,
        "whole_process_peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "aggregate_speech": totals, "clips": clips,
    }
    (output / "scores.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(totals, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "run", "calibrate"))
    parser.add_argument("--artifacts", required=True, type=Path)
    args = parser.parse_args()
    root = args.artifacts.resolve()
    if root.is_relative_to(Path(__file__).resolve().parents[2]):
        parser.error("Keep all downloaded and generated data outside this repository")
    if args.action == "prepare":
        prepare(root)
    elif args.action == "calibrate":
        prepare_calibration(root)
        run(root, calibration=True)
    else:
        run(root)


if __name__ == "__main__":
    main()
