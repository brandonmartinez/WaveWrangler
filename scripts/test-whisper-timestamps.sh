#!/usr/bin/env bash
# Exercise the actual private timestamp routine with generated energy/tokens and hardened C++ bounds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Packages/WaveWranglerKit/Sources/WWWhisperNative/upstream"

bash "$ROOT/scripts/verify-whisper-native.sh"
OUTPUT="$ROOT/.build/WhisperTimestampTests"
mkdir -p "$OUTPUT"

OBJECTS=()
for name in ggml ggml-alloc ggml-backend ggml-quants; do
  object="$OUTPUT/$name.o"
  xcrun clang -std=c11 -O0 -g -DGGML_USE_ACCELERATE -I "$SOURCE" \
    -c "$SOURCE/$name.c" -o "$object"
  OBJECTS+=("$object")
done
xcrun clang++ -std=c++11 -O0 -g \
  -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE \
  -DGGML_USE_ACCELERATE \
  "$ROOT/scripts/native/whisper-token-timestamps.cpp" \
  "${OBJECTS[@]}" -framework Accelerate \
  -o "$OUTPUT/whisper-token-timestamps"
"$OUTPUT/whisper-token-timestamps"
