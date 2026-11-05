#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
mkdir -p "$project_dir/build/tests" "$project_dir/build/module-cache"
python3 -m unittest discover -s "$project_dir/Tests" -p 'test_wikidata_builder.py'
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$project_dir/build/module-cache" "$project_dir/Sources/Models.swift" "$project_dir/Sources/Terminology.swift" "$project_dir/Tests/WikidataTests.swift" -o "$project_dir/build/tests/WikidataTests"
"$project_dir/build/tests/WikidataTests" "$project_dir"
