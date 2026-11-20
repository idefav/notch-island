#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ -z "$1" ]; }; then
    printf '用法：sh build-app.sh [输出目录]\n' >&2
    exit 2
fi
output=${1:-"$root/dist"}
mkdir -p -- "$output"
output=$(CDPATH= cd -- "$output" && pwd)
destination="$output/NotchIsland.app"
if [ -e "$destination" ] || [ -L "$destination" ]; then
    printf '目标已存在：%s\n' "$destination" >&2
    exit 1
fi

swift build --package-path "$root" -c release
products=$(swift build --package-path "$root" -c release --show-bin-path)
staging=$(mktemp -d "$output/.notch-island.XXXXXX")
trap 'rm -rf -- "$staging"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
app="$staging/NotchIsland.app"
iconset="$staging/AppIcon.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"
cp "$products/NotchIsland" "$app/Contents/MacOS/NotchIsland"
cp "$root/Info.plist" "$app/Contents/Info.plist"
swift "$root/Artwork/AppIcon.swift" "$iconset"
/usr/bin/iconutil --convert icns --output "$app/Contents/Resources/AppIcon.icns" "$iconset"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
mv -n "$app" "$output/"
if [ -e "$app" ]; then
    printf '构建期间目标已出现：%s\n' "$destination" >&2
    exit 1
fi
printf '%s\n' "$destination"
