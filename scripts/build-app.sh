#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_configuration="${1:-release}"
cd "$project_dir"
swift build -c "$build_configuration"
binary_dir="$(swift build -c "$build_configuration" --show-bin-path)"
app_dir="$project_dir/dist/Framepick.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Framepick" "$app_dir/Contents/MacOS/Framepick.next"
mv -f "$app_dir/Contents/MacOS/Framepick.next" "$app_dir/Contents/MacOS/Framepick"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
swift "$project_dir/scripts/make-icon.swift" "$project_dir/.build/AppIcon.iconset"
iconutil -c icns "$project_dir/.build/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_dir"
printf '앱 생성 완료: %s\n' "$app_dir"
