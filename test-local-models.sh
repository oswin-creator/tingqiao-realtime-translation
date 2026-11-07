#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
mkdir -p build/tests build/module-cache
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path build/module-cache Sources/Models.swift Sources/LocalModels.swift Sources/WhisperEngine.swift Tests/LocalModelTests.swift -o build/tests/LocalModelTests
build/tests/LocalModelTests
cmake_bin="${TINGQIAO_CMAKE:-}"
if [[ -z "$cmake_bin" ]]; then cmake_bin="$(command -v cmake || true)"; fi
if [[ -z "$cmake_bin" && -x "$project_dir/build/tooling/bin/cmake" ]]; then cmake_bin="$project_dir/build/tooling/bin/cmake"; fi
if [[ -z "$cmake_bin" ]]; then print -u2 "Install CMake 3.20 or later, or set TINGQIAO_CMAKE."; exit 1; fi
"$cmake_bin" -S Tools/Whisper -B build/whisper-engine -DTINGQIAO_BUILD_CONVERTER_TEST=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
"$cmake_bin" --build build/whisper-engine --target KomixConversionTests -j 4
build/whisper-engine/KomixConversionTests Tests/Fixtures/komix-header.json Resources/whisper-medium-vocab.bin build/tests/komix-converted-fixture.bin
