#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
build_dir="${TINGQIAO_BUILD_DIR:-$project_dir/build}"
module_cache="$project_dir/build/module-cache"
app_dir="$build_dir/听桥.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$module_cache"
if [[ ! -f "$project_dir/Resources/AppIcon.icns" ]]; then zsh "$project_dir/Tools/make-icon.sh"; fi
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/phone.html" "$app_dir/Contents/Resources/phone.html"
cp "$project_dir/Resources/terminology.json" "$app_dir/Contents/Resources/terminology.json"
cp "$project_dir/Resources/wikidata.json" "$project_dir/Resources/wikidata.manifest.json" "$app_dir/Contents/Resources/"
if [[ -f "$project_dir/Resources/AppIcon.icns" ]]; then cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"; fi
xcrun swiftc -file-prefix-map "$project_dir=." -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$module_cache" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$project_dir/Resources/Info.plist" "$project_dir"/Sources/*.swift -o "$app_dir/Contents/MacOS/TingQiao"
helper="$project_dir/build/whisper-engine/TingQiaoWhisper"
if [[ ! -x "$helper" ]]; then print -u2 "先运行 ./build-whisper.sh 构建本机识别引擎"; exit 1; fi
cp "$helper" "$app_dir/Contents/MacOS/TingQiaoWhisper"
xcrun swiftc -file-prefix-map "$project_dir=." -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$module_cache" "$project_dir/Sources/UpdateInstallation.swift" "$project_dir/Tools/Updater/main.swift" -o "$app_dir/Contents/MacOS/TingQiaoUpdater"
qwen_helper="$project_dir/build/qwen-engine/TingQiaoQwen"
if [[ ! -x "$qwen_helper" ]]; then print -u2 "先运行 ./build-qwen.sh 构建 Qwen 识别引擎"; exit 1; fi
cp "$qwen_helper" "$app_dir/Contents/MacOS/TingQiaoQwen"
[[ "$(shasum -a 256 "$project_dir/Resources/whisper-medium-vocab.bin" | cut -d ' ' -f 1)" == "49639ac8580c3985225c05981ed17f85c8d193ebeaaab3bde2a0cddc38d2eb56" ]] || { print -u2 "KomixV2 编码表校验失败"; exit 1; }
cp "$project_dir/Resources/whisper-medium-vocab.bin" "$app_dir/Contents/Resources/"
vad_library="$project_dir/build/whisper-engine/libTingQiaoVAD.dylib"
if [[ ! -f "$vad_library" ]]; then print -u2 "先运行 ./build-whisper.sh 构建 Silero 检测引擎"; exit 1; fi
cp "$vad_library" "$app_dir/Contents/MacOS/libTingQiaoVAD.dylib"
vad_model="$project_dir/Resources/ggml-silero-v5.1.2.bin"
[[ "$(shasum -a 256 "$vad_model" | cut -d ' ' -f 1)" == "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf" ]] || { print -u2 "Silero 模型校验失败"; exit 1; }
cp "$vad_model" "$app_dir/Contents/Resources/"
mkdir -p "$app_dir/Contents/Resources/Licenses"
cp "$project_dir"/docs/licenses/* "$app_dir/Contents/Resources/Licenses/"
cp "$project_dir/Resources/THIRD-PARTY-NOTICES.txt" "$app_dir/Contents/Resources/THIRD-PARTY-NOTICES.txt"
sign_identity="${TINGQIAO_SIGN_IDENTITY:-}"
sign_keychain="${TINGQIAO_SIGN_KEYCHAIN:-}"
local_signing="$project_dir/.local-signing"
if [[ -z "$sign_identity" && -f "$local_signing/identity.txt" ]]; then
    sign_identity="$(<"$local_signing/identity.txt")"
    sign_keychain="$local_signing/release-signing.keychain-db"
    python3 "$project_dir/Tools/Signing/unlock.py" "$local_signing"
fi
sign_identity="${sign_identity:--}"
python3 "$project_dir/Tools/Signing/sign.py" "$sign_identity" "$sign_keychain" "$app_dir"
print -r -- "$app_dir"
