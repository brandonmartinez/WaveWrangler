#!/usr/bin/env bash
# Stage the reviewed whisper.cpp/ggml closure and official English-base model off-repository.
# Usage: scripts/stage-speech-candidate.sh /absolute/path/to/ggml-base.en.bin
set -euo pipefail
umask 077

if [[ $# != 1 || "$1" != /* ]]; then
  echo "Expected one absolute, already provisioned model path" >&2
  exit 2
fi

model="$1"
cli=/opt/homebrew/Cellar/whisper.cpp/1.9.4/bin/whisper-cli
whisper=/opt/homebrew/Cellar/whisper.cpp/1.9.4/lib/libwhisper.1.9.4.dylib
ggml=/opt/homebrew/Cellar/ggml/0.25.3/lib/libggml.0.25.3.dylib
base=/opt/homebrew/Cellar/ggml/0.25.3/lib/libggml-base.0.25.3.dylib
omp=/opt/homebrew/Cellar/libomp/23.1.2/lib/libomp.dylib
backend=/opt/homebrew/Cellar/ggml/0.25.3/libexec

check_file() {
  local file="$1" size="$2" digest="$3" parent
  [[ -f "$file" && ! -L "$file" &&
     "$(/usr/bin/stat -f %d "$file")" == "$(/usr/bin/stat -f %d /private/tmp)" ]] || {
    echo "Artifact is not a local regular file on the staging volume" >&2; exit 1;
  }
  parent="${file%/*}"
  while [[ "$parent" != / ]]; do
    [[ -d "$parent" && ! -L "$parent" ]] || { echo "Symlinked artifact parent" >&2; exit 1; }
    parent="${parent%/*}"
    [[ -n "$parent" ]] || parent=/
  done
  (( ($(/usr/bin/stat -f %f "$file") & 0x40000000) == 0 )) || {
    echo "Dataless artifact refused" >&2; exit 1;
  }
  [[ "$(/usr/bin/stat -f %z "$file")" == "$size" &&
     "$(shasum -a 256 "$file" | cut -d' ' -f1)" == "$digest" ]] || {
    echo "Artifact does not match reviewed size and SHA-256" >&2; exit 1;
  }
}

check_file "$model" 147964211 a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
check_file "$cli" 660848 13650fc8ffaaa4e637c6951f7d2e492916877e70bd1b7a266fbfd0bdc597719e
check_file "$whisper" 423568 c2c6624410d3308238d855b9ad1c201e578017c435616d644a1bbcbb3f030153
check_file "$ggml" 61232 35ddda50d5c05a831509e1d15258ad81e6809e4f36d3b5baec6e6bac2811ad37
check_file "$base" 518960 0678bbbf2a6102efdc0d56278091652b6cdac3e93fe5cfd0e8a85404cadf3ca4
check_file "$omp" 725984 cb679440b0af57131274b6c0bcc11b8c18ef7ad45e2a6625ef57e90379fc2ae4
check_file "$backend/libggml-blas.so" 59424 1b0371cdd0f55c70e99eaa0461e1e997a8d67aa3b517f2b7377002659fb13192
check_file "$backend/libggml-cpu-apple_m1.so" 605024 93876b87b7e99c0147bb800f1ef823cc80b5648eb66a5ea20cd2383d235920cb
check_file "$backend/libggml-cpu-apple_m2_m3.so" 605040 0bc8edc2dfd4bbb416dfe09351265239b168b8ecf0bb234f767b936656a4ae24
check_file "$backend/libggml-cpu-apple_m4.so" 605024 ccf7c056d61a8dc9a6b461dcbc19d447cbddc2a8b66f788c0f632b2ea4657e42

stage="$(mktemp -d /private/tmp/ww-speech-XXXXXXXX)"
[[ -d "$stage" && ! -L "$stage" && "$(/usr/bin/stat -f %Sp "$stage")" == drwx------ ]] || exit 1
complete=0
cleanup() {
  if [[ "$complete" == 0 && "$stage" == /private/tmp/ww-speech-* && -d "$stage" && ! -L "$stage" ]]; then
    /bin/rm -r -- "$stage"
  fi
}
trap cleanup EXIT
mkdir "$stage/bin" "$stage/lib" "$stage/libexec" "$stage/model"
cp "$cli" "$stage/bin/whisper-cli"
cp "$whisper" "$stage/lib/libwhisper.1.dylib"
cp "$ggml" "$stage/lib/libggml.0.dylib"
cp "$base" "$stage/lib/libggml-base.0.dylib"
cp "$omp" "$stage/lib/libomp.dylib"
cp "$model" "$stage/model/ggml-base.en.bin"
for variant in libggml-blas.so libggml-cpu-apple_m1.so libggml-cpu-apple_m2_m3.so libggml-cpu-apple_m4.so; do
  cp "$backend/$variant" "$stage/libexec/$variant"
done

# Replace Homebrew's mutable absolute install names with private, relative dependency paths.
# Re-sign each changed Mach-O ad hoc; only the exact resulting bytes below are admissible.
for binary in "$stage/bin/whisper-cli" "$stage/lib/libwhisper.1.dylib"; do
  install_name_tool -change /opt/homebrew/opt/ggml/lib/libggml.0.dylib \
    @loader_path/../lib/libggml.0.dylib \
    -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib \
    @loader_path/../lib/libggml-base.0.dylib "$binary"
done
install_name_tool -change @loader_path/../lib/libggml.0.dylib @loader_path/libggml.0.dylib \
  -change @loader_path/../lib/libggml-base.0.dylib @loader_path/libggml-base.0.dylib \
  "$stage/lib/libwhisper.1.dylib"
install_name_tool -change @rpath/libggml-base.0.dylib @loader_path/libggml-base.0.dylib \
  "$stage/lib/libggml.0.dylib"
install_name_tool -change /opt/homebrew/opt/libomp/lib/libomp.dylib @loader_path/libomp.dylib \
  "$stage/lib/libggml-base.0.dylib"
for binary in "$stage/libexec/"*.so; do
  install_name_tool -change @rpath/libggml-base.0.dylib @loader_path/../lib/libggml-base.0.dylib \
    -change /opt/homebrew/opt/libomp/lib/libomp.dylib @loader_path/../lib/libomp.dylib "$binary"
done
for binary in "$stage/bin/whisper-cli" "$stage/lib/"*.dylib "$stage/libexec/"*.so; do
  codesign --force --sign - "$binary" >/dev/null
done

check_file "$stage/bin/whisper-cli" 657008 02b6938b489381f6a528a4a8883264ea56eed76c7423b803d21394297b2c4834
check_file "$stage/lib/libwhisper.1.dylib" 421104 eca0dcf2178dd2f1903ebb502f10903932ee764070cc46d63d14ffd3d1fa024b
check_file "$stage/lib/libggml.0.dylib" 60896 02256126859de0555e777e78e6447d8102b0edea4a995f275c3106b3a7c65db8
check_file "$stage/lib/libggml-base.0.dylib" 515952 84a8ec249803e5da0c28800b0c1699c8a92e1b52e6d2931faecacf35e4901126
check_file "$stage/lib/libomp.dylib" 721776 66ea5824d7cf242e3a00e00480d7ccd60e100bd0665bdb69dabb2326728e38f4
check_file "$stage/libexec/libggml-blas.so" 59216 99ca2ef77f56896b07351ac8a03e242b28201546a417b2ff6ee5a9c395b252e2
check_file "$stage/libexec/libggml-cpu-apple_m1.so" 601520 e01bd177f9889e95efb990203fde896910f78237e96a798e115fa662f025b46a
check_file "$stage/libexec/libggml-cpu-apple_m2_m3.so" 601520 827a2d6f05db7bd2fc2e4ee73e767ca54d381a86de5f1a71e2e6f91df12b6c8e
check_file "$stage/libexec/libggml-cpu-apple_m4.so" 601520 c2fb157016389e35b61695a3c021675b715c6285b1caefdfa056a1d5e8624905
check_file "$stage/model/ggml-base.en.bin" 147964211 a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
check_file "$model" 147964211 a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
complete=1
printf '%s\n' "$stage"
