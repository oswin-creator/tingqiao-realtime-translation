#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
revision=5700f127e38dd53c4735ea23ef743b4b538eacd4
vendor_dir="$project_dir/build/vendor/transcribe.cpp"
if [[ ! -d "$vendor_dir" ]]; then
  mkdir -p "$vendor_dir"
  git -C "$vendor_dir" init
  git -C "$vendor_dir" remote add origin https://github.com/handy-computer/transcribe.cpp.git
  git -C "$vendor_dir" fetch --depth 1 origin "$revision"
  git -C "$vendor_dir" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$vendor_dir" rev-parse HEAD)" == "$revision" ]] || { print -u2 "Qwen 引擎源码版本不匹配"; exit 1; }
cmake_bin="${TINGQIAO_CMAKE:-}"
if [[ -z "$cmake_bin" ]]; then cmake_bin="$(command -v cmake || true)"; fi
if [[ -z "$cmake_bin" && -x "$project_dir/build/tooling/bin/cmake" ]]; then cmake_bin="$project_dir/build/tooling/bin/cmake"; fi
if [[ -z "$cmake_bin" ]]; then print -u2 "Install CMake 3.20 or later, or set TINGQIAO_CMAKE."; exit 1; fi
"$cmake_bin" -S Tools/Qwen -B build/qwen-engine -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
"$cmake_bin" --build build/qwen-engine --target TingQiaoQwen -j 6
