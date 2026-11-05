#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
sdk_dir="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
tools_dir="$sdk_dir/build-tools/36.0.0"
java_dir="$(/usr/libexec/java_home -v 17)"
platform_jar="$sdk_dir/platforms/android-35/android.jar"
build_dir="$project_dir/build/tests"
mkdir -p "$build_dir/classes" "$build_dir/dex"
"$tools_dir/aapt" package -f -M "$project_dir/tests/AndroidManifest.xml" -I "$platform_jar" -F "$build_dir/resources.apk"
"$java_dir/bin/javac" --release 8 -classpath "$platform_jar:$project_dir/build/classes" -d "$build_dir/classes" "$project_dir"/tests/src/cn/tingqiao/tests/*.java
"$java_dir/bin/jar" cf "$build_dir/tests.jar" -C "$build_dir/classes" .
JAVA_HOME="$java_dir" "$tools_dir/d8" --lib "$platform_jar" --classpath "$project_dir/build/classes.jar" --min-api 26 --output "$build_dir/dex" "$build_dir/tests.jar"
cp "$build_dir/resources.apk" "$build_dir/unsigned.apk"
(cd "$build_dir/dex" && /usr/bin/zip -q "$build_dir/unsigned.apk" classes.dex)
"$tools_dir/zipalign" -f 4 "$build_dir/unsigned.apk" "$build_dir/aligned.apk"
JAVA_HOME="$java_dir" "$tools_dir/apksigner" sign --ks "$project_dir/build/preview.keystore" --ks-key-alias tingqiao-preview --ks-pass pass:android --key-pass pass:android --out "$build_dir/test.apk" "$build_dir/aligned.apk"
print -r -- "$build_dir/test.apk"
