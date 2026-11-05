#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
sdk_dir="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
tools_dir="$sdk_dir/build-tools/36.0.0"
platform_jar="$sdk_dir/platforms/android-35/android.jar"
build_dir="$project_dir/build"
java_dir="$(/usr/libexec/java_home -v 17)"
zsh "$project_dir/../scripts/fetch-android-deps.sh"
mkdir -p "$build_dir/classes" "$build_dir/dex"
"$tools_dir/aapt" package -f -M "$project_dir/app/src/main/AndroidManifest.xml" -S "$project_dir/app/src/main/res" -A "$project_dir/app/src/main/assets" -I "$platform_jar" -F "$build_dir/resources.apk"
"$java_dir/bin/javac" --release 8 -classpath "$platform_jar:$project_dir/libs/zxing-core-3.5.3.jar" -d "$build_dir/classes" "$project_dir"/app/src/main/java/cn/tingqiao/companion/*.java
"$java_dir/bin/jar" cf "$build_dir/classes.jar" -C "$build_dir/classes" .
JAVA_HOME="$java_dir" "$tools_dir/d8" --lib "$platform_jar" --min-api 26 --output "$build_dir/dex" "$build_dir/classes.jar" "$project_dir/libs/zxing-core-3.5.3.jar"
cp "$build_dir/resources.apk" "$build_dir/unsigned.apk"
(cd "$build_dir/dex" && /usr/bin/zip -q "$build_dir/unsigned.apk" classes.dex)
"$tools_dir/zipalign" -f 4 "$build_dir/unsigned.apk" "$build_dir/aligned.apk"
if [[ ! -f "$build_dir/preview.keystore" ]]; then
    "$java_dir/bin/keytool" -genkeypair -keystore "$build_dir/preview.keystore" -alias tingqiao-preview -keyalg RSA -keysize 2048 -validity 3650 -storepass android -keypass android -dname "CN=TingQiao Preview"
fi
JAVA_HOME="$java_dir" "$tools_dir/apksigner" sign --ks "$build_dir/preview.keystore" --ks-key-alias tingqiao-preview --ks-pass pass:android --key-pass pass:android --out "$build_dir/听桥字幕.apk" "$build_dir/aligned.apk"
JAVA_HOME="$java_dir" "$tools_dir/apksigner" verify "$build_dir/听桥字幕.apk"
print -r -- "$build_dir/听桥字幕.apk"
