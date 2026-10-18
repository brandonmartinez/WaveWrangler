#!/usr/bin/env bash
# A deliberately resource-less executable must refuse Metal, not silently infer on CPU.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="${1:?Supply the explicitly downloaded public pinned base.en model}"
SOURCE="$ROOT/Packages/WaveWranglerKit/Sources/WWWhisperNative"
EXPECTED=a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
[[ "$(shasum -a 256 "$MODEL" | cut -d ' ' -f 1)" == "$EXPECTED" ]] || { echo "Pinned public model hash mismatch" >&2; exit 1; }
bash "$ROOT/scripts/verify-whisper-native.sh"
OUTPUT="$ROOT/.build/WhisperBackendTests"
mkdir -p "$OUTPUT"
OBJECTS=()
for name in ggml ggml-alloc ggml-backend ggml-quants; do
  xcrun clang -O3 -DNDEBUG -std=c11 -DGGML_USE_ACCELERATE -DGGML_USE_METAL -I "$SOURCE/upstream" \
    -c "$SOURCE/upstream/$name.c" -o "$OUTPUT/$name.o"
  OBJECTS+=("$OUTPUT/$name.o")
done
for name in upstream/ggml-metal.m Hardware.m CPUBridge.c; do
  object="$OUTPUT/$(basename "$name").o"
  xcrun clang -O3 -DNDEBUG -fno-objc-arc -DGGML_USE_METAL -I "$SOURCE/upstream" -I "$SOURCE/include" \
    -c "$SOURCE/$name" -o "$object"
  OBJECTS+=("$object")
done
xcrun clang++ -O3 -DNDEBUG -std=c++11 -DGGML_USE_ACCELERATE -DGGML_USE_METAL -I "$SOURCE/upstream" \
  "$ROOT/scripts/native/whisper-backend-refusal.cpp" "$SOURCE/upstream/whisper.cpp" "${OBJECTS[@]}" \
  -framework Accelerate -framework Foundation -framework Metal -o "$OUTPUT/whisper-backend-refusal"
"$OUTPUT/whisper-backend-refusal" "$MODEL"
