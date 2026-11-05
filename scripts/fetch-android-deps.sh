#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
jar_dir="$project_dir/android/libs"
jar_file="$jar_dir/zxing-core-3.5.3.jar"
expected="8d8064c1636fdaef7189dd9055c7d59950a8940a12f2293956446ec3c109fd82"
mkdir -p "$jar_dir"
if [[ -f "$jar_file" ]] && [[ "$(shasum -a 256 "$jar_file" | cut -d ' ' -f 1)" == "$expected" ]]; then
    print "ZXing Core 3.5.3 is ready."
    exit 0
fi
temporary="$(mktemp "$jar_dir/.zxing.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 --retry 2 \
    'https://repo.maven.apache.org/maven2/com/google/zxing/core/3.5.3/core-3.5.3.jar' \
    -o "$temporary"
actual="$(shasum -a 256 "$temporary" | cut -d ' ' -f 1)"
if [[ "$actual" != "$expected" ]]; then
    print -u2 "ZXing checksum mismatch. The dependency was not installed."
    exit 1
fi
mv "$temporary" "$jar_file"
print "ZXing Core 3.5.3 is ready."
