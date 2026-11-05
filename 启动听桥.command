#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
if [[ ! -x "$project_dir/build/听桥.app/Contents/MacOS/TingQiao" ]]; then
    zsh "$project_dir/build.sh"
fi
open "$project_dir/build/听桥.app"
