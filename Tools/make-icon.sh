#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
mkdir -p "$project_dir/build/module-cache" "$project_dir/build/icon-png" "$project_dir/build/AppIcon.iconset"
xcrun swift -module-cache-path "$project_dir/build/module-cache" "$project_dir/Tools/GenerateIcon.swift" "$project_dir/build/icon-png"
for icon_size in 16 32 128 256 512; do
  cp "$project_dir/build/icon-png/$icon_size.png" "$project_dir/build/AppIcon.iconset/icon_${icon_size}x${icon_size}.png"
  retina_size=$((icon_size * 2))
  cp "$project_dir/build/icon-png/$retina_size.png" "$project_dir/build/AppIcon.iconset/icon_${icon_size}x${icon_size}@2x.png"
done
python3 "$project_dir/Tools/PackIcon.py" "$project_dir/build/icon-png" "$project_dir/Resources/AppIcon.icns"
