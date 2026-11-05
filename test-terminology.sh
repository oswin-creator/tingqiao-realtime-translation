#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
mkdir -p "$project_dir/build/tests" "$project_dir/build/module-cache"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$project_dir/build/module-cache" "$project_dir/Sources/Models.swift" "$project_dir/Sources/Terminology.swift" "$project_dir/Sources/Translation.swift" "$project_dir/Tests/TerminologyTests.swift" -o "$project_dir/build/tests/TerminologyTests"
"$project_dir/build/tests/TerminologyTests" "$project_dir"
