#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ -z "$1" ]; }; then
    printf '用法：sh build-dmg.sh [输出目录]\n' >&2
    exit 2
fi

output=${1:-"$root/dist"}
mkdir -p -- "$output"
output=$(CDPATH= cd -- "$output" && pwd)
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Info.plist")
case "$version" in
    ''|*[!0-9.]*)
        printf '无效的应用版本：%s\n' "$version" >&2
        exit 1
        ;;
esac

staging=$(mktemp -d "$output/.notch-island-dmg.XXXXXX")
mount="$staging/mount"
attached=false
cleanup() {
    status=$?
    if "$attached" && ! hdiutil detach "$mount" -quiet; then
        printf '已保留待卸载目录：%s\n' "$staging" >&2
        exit 1
    fi
    rm -rf -- "$staging"
    exit "$status"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

layout="$staging/image"
sh "$root/build-app.sh" "$layout"
app="$layout/NotchIsland.app"
architecture=$(xcrun lipo -archs "$app/Contents/MacOS/NotchIsland")
if [ "$architecture" != arm64 ]; then
    printf '发行包需要 arm64 构建，当前编译结果为 %s\n' "$architecture" >&2
    exit 1
fi
asset="NotchIsland-$version-$architecture.dmg"
checksum="$asset.sha256"
for name in "$asset" "$checksum"; do
    if [ -e "$output/$name" ] || [ -L "$output/$name" ]; then
        printf '目标已存在：%s\n' "$output/$name" >&2
        exit 1
    fi
done

ln -s /Applications "$layout/Applications"
hdiutil create -quiet -volname NotchIsland -srcfolder "$layout" -fs 'HFS+' -format UDZO "$staging/$asset"
hdiutil verify -quiet "$staging/$asset"
mkdir "$mount"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$staging/$asset"
attached=true

mounted_app="$mount/NotchIsland.app"
codesign --verify --strict "$mounted_app"
xcrun lipo -verify_arch arm64 "$mounted_app/Contents/MacOS/NotchIsland"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mounted_app/Contents/Info.plist")" = "$version"
test -s "$mounted_app/Contents/Resources/AppIcon.icns"
test "$(readlink "$mount/Applications")" = /Applications
hdiutil detach "$mount" -quiet
attached=false

(cd "$staging" && shasum -a 256 "$asset" > "$checksum" && shasum -a 256 -c "$checksum")
for name in "$asset" "$checksum"; do
    mv -n "$staging/$name" "$output/"
    if [ -e "$staging/$name" ]; then
        printf '构建期间目标已出现：%s\n' "$output/$name" >&2
        exit 1
    fi
done
printf '%s\n' "$output/$asset"
