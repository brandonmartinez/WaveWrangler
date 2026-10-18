#!/usr/bin/env bash
# Candidate sources are the three ggml-metal files and four coreml/whisper-encoder
# files from whisper.cpp v1.6.2, downloaded separately into an external directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CANDIDATE="${1:?external candidate source directory}"
SOURCE="$ROOT/Packages/WaveWranglerKit/Sources/WWWhisperNative/upstream"
mkdir -p "$CANDIDATE/objects" "$CANDIDATE/runtime"

# Runtime source compilation, like upstream's fallback, but with its common header inlined.
python3 - "$SOURCE" "$CANDIDATE" <<'PY'
import sys
from pathlib import Path
source, candidate = map(Path, sys.argv[1:])
metal = (candidate / "ggml-metal.metal").read_text()
(candidate / "runtime/ggml-metal.metal").write_text(
    metal.replace('#include "ggml-common.h"', (source / "ggml-common.h").read_text()))
# No unsupported ANE API: permit CPU+ANE for this separately labelled experiment.
encoder = (candidate / "coreml/whisper-encoder.mm").read_text()
(candidate / "coreml/encoder-cpu-ane.mm").write_text(
    encoder.replace("config.computeUnits = MLComputeUnitsAll;",
                    "config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;"))
PY

OBJECTS=()
for name in ggml ggml-alloc ggml-backend ggml-quants; do
  xcrun clang -O3 -DNDEBUG -std=c11 -DGGML_USE_ACCELERATE -DGGML_USE_METAL \
    -I "$SOURCE" -I "$CANDIDATE" -c "$SOURCE/$name.c" -o "$CANDIDATE/objects/$name.o"
  OBJECTS+=("$CANDIDATE/objects/$name.o")
done
xcrun clang -O3 -DNDEBUG -fno-objc-arc -DGGML_USE_METAL -I "$SOURCE" -I "$CANDIDATE" \
  -c "$CANDIDATE/ggml-metal.m" -o "$CANDIDATE/objects/ggml-metal.o"
OBJECTS+=("$CANDIDATE/objects/ggml-metal.o")
COMMON=(-O3 -DNDEBUG -std=c++11 -DGGML_USE_ACCELERATE -DGGML_USE_METAL
  -I "$SOURCE" -I "$CANDIDATE" "$ROOT/scripts/native/whisper-acceleration.cpp")
xcrun clang++ "${COMMON[@]}" "${OBJECTS[@]}" -framework Accelerate -framework Foundation -framework Metal \
  -o "$CANDIDATE/acceleration"
xcrun clang -O3 -fobjc-arc -I "$CANDIDATE/coreml" \
  -c "$CANDIDATE/coreml/whisper-encoder-impl.m" -o "$CANDIDATE/objects/encoder-impl.o"
xcrun clang++ -O3 -std=c++11 -fobjc-arc -I "$CANDIDATE/coreml" \
  -c "$CANDIDATE/coreml/encoder-cpu-ane.mm" -o "$CANDIDATE/objects/encoder.o"
xcrun clang++ "${COMMON[@]}" -DWHISPER_USE_COREML "${OBJECTS[@]}" \
  "$CANDIDATE/objects/encoder.o" "$CANDIDATE/objects/encoder-impl.o" \
  -framework Accelerate -framework Foundation -framework Metal -framework CoreML \
  -o "$CANDIDATE/acceleration-coreml"
