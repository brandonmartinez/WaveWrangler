#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Packages/WaveWranglerKit/Sources/WWWhisperNative/upstream"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fixture="$scratch/fixture"
vendor="$fixture/Packages/WaveWranglerKit/Sources/WWWhisperNative/upstream"
mkdir -p "$fixture/scripts" "$(dirname "$vendor")"
cp "$ROOT/scripts/verify-whisper-native.sh" "$fixture/scripts/"
cp -R "$SOURCE" "$vendor"

verify="$fixture/scripts/verify-whisper-native.sh"
bash "$verify"

expect_rejection() {
  local label="$1" expected="$2" output
  if output="$(bash "$verify" 2>&1)"; then
    echo "Verifier accepted $label" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "Verifier rejected $label for the wrong reason: $output" >&2
    exit 1
  fi
  echo "Rejected $label"
}

ln -s ggml.h "$vendor/extra.h"
expect_rejection "extra symlink" "Unexpected path count"
if output="$(GLOBIGNORE=extra.h bash "$verify" 2>&1)"; then
  echo "Verifier accepted extra symlink with GLOBIGNORE set" >&2
  exit 1
fi
if [[ "$output" != *"Unexpected path count"* ]]; then
  echo "Verifier rejected extra symlink with GLOBIGNORE for the wrong reason: $output" >&2
  exit 1
fi
rm "$vendor/extra.h"

touch "$vendor/.extra.h"
expect_rejection "hidden path" "Unexpected path count"
rm "$vendor/.extra.h"

mkdir "$vendor/extra"
expect_rejection "extra directory" "Unexpected path count"
rmdir "$vendor/extra"

mv "$vendor/ggml-common.h" "$vendor/extra-header.h"
expect_rejection "equal-count substituted path" "Unexpected path or type"
mv "$vendor/extra-header.h" "$vendor/ggml-common.h"

mkfifo "$vendor/extra.pipe"
expect_rejection "extra special input" "Unexpected path count"
rm "$vendor/extra.pipe"

printf '\n// compromised pinned header\n' >> "$vendor/ggml.h"
expect_rejection "compromised pinned header" "source hash mismatch"
cp "$SOURCE/ggml.h" "$vendor/ggml.h"

mv "$vendor/ggml.h" "$scratch/ggml.h"
ln -s "$scratch/ggml.h" "$vendor/ggml.h"
expect_rejection "symlink replacing pinned header" "Unexpected path or type"
rm "$vendor/ggml.h"
mv "$scratch/ggml.h" "$vendor/ggml.h"

mv "$vendor" "$scratch/upstream-real"
ln -s "$scratch/upstream-real" "$vendor"
expect_rejection "symlinked upstream directory" "must be a real directory"
