#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
force=0
make_dmg=0
output=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force|-f)
            force=1
            shift
            ;;
        --dmg)
            make_dmg=1
            shift
            ;;
        -*)
            printf '用法：sh build-app.sh [--force] [--dmg] [输出目录]\n' >&2
            exit 2
            ;;
        *)
            if [ -n "$output" ] || [ -z "$1" ]; then
                printf '用法：sh build-app.sh [--force] [--dmg] [输出目录]\n' >&2
                exit 2
            fi
            output=$1
            shift
            ;;
    esac
done

output=${output:-"$root/dist"}
mkdir -p -- "$output"
output=$(CDPATH= cd -- "$output" && pwd)
destination="$output/NotchIsland.app"
if [ "$force" -eq 0 ] && { [ -e "$destination" ] || [ -L "$destination" ]; }; then
    printf '目标已存在（可加 --force 覆盖）：%s\n' "$destination" >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Info.plist")
dmg_destination="$output/NotchIsland-$version.dmg"
if [ "$make_dmg" -eq 1 ] && [ "$force" -eq 0 ] && { [ -e "$dmg_destination" ] || [ -L "$dmg_destination" ]; }; then
    printf 'DMG 目标已存在（可加 --force 覆盖）：%s\n' "$dmg_destination" >&2
    exit 1
fi

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    identity=$CODESIGN_IDENTITY
else
    detected=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ { print $2; exit }')
    identity=${detected:--}
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
codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"

if [ "$force" -eq 1 ] && { [ -e "$destination" ] || [ -L "$destination" ]; }; then
    backup="$staging/previous.app"
    mv "$destination" "$backup"
    if ! mv "$app" "$destination"; then
        mv "$backup" "$destination" 2>/dev/null || true
        printf '替换目标失败：%s\n' "$destination" >&2
        exit 1
    fi
else
    mv -n "$app" "$output/"
    if [ -e "$app" ]; then
        printf '构建期间目标已出现：%s\n' "$destination" >&2
        exit 1
    fi
fi
printf '%s\n' "$destination"

if [ "$make_dmg" -eq 1 ]; then
    dmg_root="$staging/dmg-root"
    dmg_staging="$staging/NotchIsland-$version.dmg"
    mkdir -p "$dmg_root"
    cp -R "$destination" "$dmg_root/NotchIsland.app"
    ln -s /Applications "$dmg_root/Applications"
    /usr/bin/hdiutil create -volname "菜单栏灵动岛" -srcfolder "$dmg_root" -ov -format UDZO "$dmg_staging" >/dev/null
    mv -f "$dmg_staging" "$dmg_destination"
    printf '%s\n' "$dmg_destination"
fi
