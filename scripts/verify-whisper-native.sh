#!/usr/bin/env bash
# Verify the exact official v1.6.2 CPU source subset; no model or generated artifact is vendored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Packages/WaveWranglerKit/Sources/WWWhisperNative/upstream"
EXPECTED=b4a7363a36dfeb9812b4d68d91f1b01f16af80edf4c9803aaf985f26033a9942
if [[ ! -d "$SOURCE" || -L "$SOURCE" ]]; then
  echo "Vendored CPU source must be a real directory" >&2
  exit 1
fi
cd "$SOURCE"
FILES=(
  LICENSE whisper.cpp whisper.h ggml.c ggml.h ggml-alloc.c ggml-alloc.h
  ggml-backend.c ggml-backend.h ggml-backend-impl.h ggml-quants.c ggml-quants.h
  ggml-common.h ggml-impl.h
)
unset GLOBIGNORE
shopt -s dotglob nullglob
entries=(*)
if [[ "${#entries[@]}" != "${#FILES[@]}" ]]; then
  echo "Unexpected path count in vendored CPU source" >&2
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
    echo "Unexpected path or type in vendored CPU source: $entry" >&2
    exit 1
  fi
done
ACTUAL="$(shasum -a 256 "${FILES[@]}" | shasum -a 256 | cut -d ' ' -f 1)"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "Pinned whisper.cpp v1.6.2 CPU source hash mismatch" >&2
  exit 1
fi
echo "Pinned whisper.cpp v1.6.2 CPU source verified"
