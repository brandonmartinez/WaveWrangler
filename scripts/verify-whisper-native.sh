#!/usr/bin/env bash
# Verify v1.6.2 plus local timestamp/backend/bundle fixes; no model is vendored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Packages/WaveWranglerKit/Sources/WWWhisperNative/upstream"
EXPECTED=031897a71dcc8180aa64004a73c14e4032634a121fe235347c925a3f9378526d
if [[ ! -d "$SOURCE" || -L "$SOURCE" ]]; then
  echo "Vendored native source must be a real directory" >&2
  exit 1
fi
cd "$SOURCE"
FILES=(
  LICENSE whisper.cpp whisper.h ggml.c ggml.h ggml-alloc.c ggml-alloc.h
  ggml-backend.c ggml-backend.h ggml-backend-impl.h ggml-quants.c ggml-quants.h
  ggml-common.h ggml-impl.h
  ggml-metal.h ggml-metal.m ggml-metal.metal
)
unset GLOBIGNORE
shopt -s dotglob nullglob
entries=(*)
if [[ "${#entries[@]}" != "${#FILES[@]}" ]]; then
  echo "Unexpected path count in vendored native source" >&2
  exit 1
fi
for entry in "${entries[@]}"; do
  found=0
  for file in "${FILES[@]}"; do
    if [[ "$entry" == "$file" ]]; then
      found=1
      break
    fi
  done
  if [[ "$found" != 1 || ! -f "$entry" || -L "$entry" ]]; then
    echo "Unexpected path or type in vendored native source: $entry" >&2
    exit 1
  fi
done
ACTUAL="$(shasum -a 256 "${FILES[@]}" | shasum -a 256 | cut -d ' ' -f 1)"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "Pinned whisper.cpp v1.6.2+ww-token-bounds-v1+metal-v1 source hash mismatch" >&2
  exit 1
fi
echo "Pinned whisper.cpp v1.6.2+ww-token-bounds-v1+metal-v1 source verified"
