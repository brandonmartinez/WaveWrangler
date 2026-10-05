#!/usr/bin/env bash
# Generate a synthetic "messy recorder folder" for the M1 demonstration (docs/m1/evidence/m1-demonstration.md).
#
# Every file is small random bytes with an audio or decoy extension. Nothing is a real recording,
# nothing is decodable, and nothing is copied from user media.
#
# Usage: scripts/demo/make-synthetic-episode.sh [OUTPUT_DIR]
#   OUTPUT_DIR defaults to "$TMPDIR/ww-m1-demo". It must not exist yet (or be empty) and must be
#   outside any Git working tree.
set -euo pipefail

OUT="${1:-${TMPDIR:-/tmp}/ww-m1-demo}"
OUT="${OUT%/}"

if [[ -e "$OUT" ]] && [[ -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then
  echo "error: $OUT already exists and is not empty; choose another folder or remove it first" >&2
  exit 1
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
if git -C "$OUT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: $OUT is inside a Git working tree; synthetic media must stay outside repositories" >&2
  exit 1
fi

EPISODE="$OUT/Synthetic Episode 1"
RELINK="$OUT/Relink Target"

# rand_file PATH BYTES — random bytes, never a valid audio stream.
rand_file() {
  mkdir -p "$(dirname "$1")"
  head -c "$2" /dev/urandom >"$1"
}

# Recorder A: two takes (epochs) in take folders, file-name track pattern.
rand_file "$EPISODE/Recorder A/ZOOM0001/ZOOM0001_Tr1.WAV" 65536
rand_file "$EPISODE/Recorder A/ZOOM0001/ZOOM0001_Tr2.WAV" 65536
rand_file "$EPISODE/Recorder A/ZOOM0001/ZOOM0001_LR.WAV" 49152
rand_file "$EPISODE/Recorder A/ZOOM0002/ZOOM0002_Tr1.WAV" 32768
rand_file "$EPISODE/Recorder A/ZOOM0002/ZOOM0002_Tr2.WAV" 32768
# Recorder B: per-person laptop recordings, including a backup by name.
rand_file "$EPISODE/Recorder B/Alpha mic.m4a" 40960
rand_file "$EPISODE/Recorder B/Bravo mic.m4a" 40960
rand_file "$EPISODE/Recorder B/Bravo backup.m4a" 20480
# Recorder C: remote guest isolated track.
rand_file "$EPISODE/Recorder C/Guest 1 iso.aif" 24576

# Decoys that must be skipped and never opened.
rand_file "$EPISODE/notes.txt" 512
rand_file "$EPISODE/synthetic-transcript.srt" 512
rand_file "$EPISODE/Recorder A/ZOOM0001/ZOOM0001.pk" 1024
rand_file "$EPISODE/Synthetic Session.logicx/Alternatives/000/ProjectData" 2048
rand_file "$EPISODE/Synthetic Session.logicx/Media/Audio Files/inside-bundle.wav" 4096
rand_file "$EPISODE/.hidden-cache" 256
rand_file "$EPISODE/cover.png" 2048

# Empty folder used as the "moved to" destination during the relink step.
mkdir -p "$RELINK"

audio=$(find "$EPISODE" -path '*.logicx' -prune -o -type f \( -iname '*.wav' -o -iname '*.m4a' -o -iname '*.aif' \) -print | wc -l | tr -d ' ')
all=$(find "$EPISODE" -type f | wc -l | tr -d ' ')
echo "Synthetic episode folder: $EPISODE"
echo "Relink target folder:     $RELINK"
echo "Files: $all total; $audio importable audio (outside the project bundle); the rest are decoys."
echo "Expected Import Review: 9 sources; groups Recorder A (epochs ZOOM0001, ZOOM0002), Recorder B, Recorder C."
