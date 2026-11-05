#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
if [[ ! -d build/vendor/whisper.cpp ]]; then
  mkdir -p build/vendor
  git clone --depth 1 --branch v1.8.2 https://github.com/ggml-org/whisper.cpp.git build/vendor/whisper.cpp
fi
expected_commit="4979e04f5dcaccb36057e059bbaed8a2f5288315"
actual_commit="$(git -C build/vendor/whisper.cpp rev-parse HEAD)"
if [[ "$actual_commit" != "$expected_commit" ]]; then
  print -u2 "whisper.cpp checkout does not match the pinned revision."
  exit 1
fi
cmake_bin="${TINGQIAO_CMAKE:-}"
if [[ -z "$cmake_bin" ]]; then
  cmake_bin="$(command -v cmake || true)"
fi
if [[ -z "$cmake_bin" && -x "$project_dir/build/tooling/bin/cmake" ]]; then
  cmake_bin="$project_dir/build/tooling/bin/cmake"
fi
if [[ -z "$cmake_bin" ]]; then
  print -u2 "Install CMake 3.20 or later, or set TINGQIAO_CMAKE to its executable."
  exit 1
fi
"$cmake_bin" -S Tools/Whisper -B build/whisper-engine -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
"$cmake_bin" --build build/whisper-engine -j 6
