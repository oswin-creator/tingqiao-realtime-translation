#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
build_dir="${TINGQIAO_BUILD_DIR:-$project_dir/build}"
module_cache="$project_dir/build/module-cache"
app_dir="$build_dir/听桥.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$module_cache"
if [[ ! -f "$project_dir/Resources/AppIcon.icns" ]]; then
    zsh "$project_dir/Tools/make-icon.sh"
fi
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/phone.html" "$app_dir/Contents/Resources/phone.html"
if [[ -f "$project_dir/Resources/AppIcon.icns" ]]; then cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"; fi
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$module_cache" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$project_dir/Resources/Info.plist" "$project_dir"/Sources/*.swift -o "$app_dir/Contents/MacOS/TingQiao"
helper="$project_dir/build/whisper-engine/TingQiaoWhisper"
if [[ ! -x "$helper" ]]; then print -u2 "先运行 ./build-whisper.sh 构建本机识别引擎"; exit 1; fi
cp "$helper" "$app_dir/Contents/MacOS/TingQiaoWhisper"
mkdir -p "$app_dir/Contents/Resources/Licenses"
cp "$project_dir"/docs/licenses/* "$app_dir/Contents/Resources/Licenses/"
cp "$project_dir/Resources/THIRD-PARTY-NOTICES.txt" "$app_dir/Contents/Resources/THIRD-PARTY-NOTICES.txt"
sign_identity="${TINGQIAO_SIGN_IDENTITY:--}"
codesign --force --sign "$sign_identity" "$app_dir/Contents/MacOS/TingQiaoWhisper"
codesign --force --deep --sign "$sign_identity" --identifier cn.tingqiao.bridge "$app_dir"
codesign --verify --deep --strict "$app_dir"
print -r -- "$app_dir"
