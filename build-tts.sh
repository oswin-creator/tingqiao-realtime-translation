#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
deps="$project_dir/build/tts-deps"
output="$project_dir/build/tts-engine"
mkdir -p "$deps" "$output"

fetch() {
    local name="$1" hash="$2" url="$3"
    local artifact="$deps/$name"
    if [[ ! -f "$artifact" || "$(shasum -a 256 "$artifact" | cut -d ' ' -f 1)" != "$hash" ]]; then
        curl -fLSs --retry 2 -o "$artifact.part" "$url"
        [[ "$(shasum -a 256 "$artifact.part" | cut -d ' ' -f 1)" == "$hash" ]]
        mv "$artifact.part" "$artifact"
    fi
}

sherpa="sherpa-onnx-v1.13.6-osx-arm64-shared-lib"
fetch sherpa.tar.bz2 d628e43aed6b719be163549876f41c909b75df26b8f439a5af69de03896bc6f5 "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.6/$sherpa.tar.bz2"
fetch sherpa-c-api.h 426db2c6acfb51e02143aece67c45779fae699d961c7c26ccf6f1388fdeaa2df "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.6/sherpa-onnx/c-api/c-api.h"
fetch onnxruntime_c_api.h 9ed0d7054a4e74249467365b25b415d36f51a44a6349e2a994a1812e4723d1e2 "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.24.1/include/onnxruntime/core/session/onnxruntime_c_api.h"
fetch onnxruntime_ep_c_api.h e94ac3490697bdb107844fa9d403952ee7136134132a057eae5c1207b57ce352 "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.24.1/include/onnxruntime/core/session/onnxruntime_ep_c_api.h"
fetch speech.zip f6556c41b2bccfd905ddbee73f8c2bf195080d9c015418a39282edb9e55c9bdb "https://github.com/nyosegawa/speech.cpp/releases/download/v0.9.0/speech-0.9.0-macos-arm64-metal.zip"
tar -xjf "$deps/sherpa.tar.bz2" -C "$deps"
unzip -p "$deps/speech.zip" speech > "$output/TingQiaoQwenTTS.part"
chmod 755 "$output/TingQiaoQwenTTS.part"
mv "$output/TingQiaoQwenTTS.part" "$output/TingQiaoQwenTTS"
cp "$deps/$sherpa/lib/"{libsherpa-onnx-c-api.dylib,libonnxruntime.dylib} "$output/"
xcrun clang++ -std=c++17 -O2 -fobjc-arc -arch arm64 -mmacosx-version-min=15.5 \
    -I"$deps" "$project_dir/Tools/TTS/main.mm" -L"$output" -lsherpa-onnx-c-api -lonnxruntime \
    -Wl,-rpath,@executable_path -framework Foundation -o "$output/TingQiaoSherpaTTS"
print -r -- "$output"
