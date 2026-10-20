#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_dir="$project_dir/dist"
app_dir="$output_dir/Codex Companion.app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$project_dir/Resources/Info.plist")
archive_path="$output_dir/CodexCompanion-v${version}-macOS-$(uname -m).zip"

cd "$project_dir"
swift build -c release

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
binary_dir="$(swift build -c release --show-bin-path)"
cp "$binary_dir/CodexCompanion" "$app_dir/Contents/MacOS/CodexCompanion"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_dir"
rm -f "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive_path"

printf '%s\n' "$app_dir"
printf '%s\n' "$archive_path"
