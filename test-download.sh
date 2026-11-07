#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
mkdir -p build/tests build/module-cache
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path build/module-cache Sources/ModelDownloader.swift Tests/ModelDownloadTests.swift -o build/tests/ModelDownloadTests
port_file="$(mktemp "$project_dir/build/tests/download-port.XXXXXX")"
rm "$port_file"
python3 Tests/model-download-server.py "$port_file" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -f "$port_file"' EXIT
for attempt in {1..100}; do
    [[ -s "$port_file" ]] && break
    sleep 0.05
done
build/tests/ModelDownloadTests "$port_file"
