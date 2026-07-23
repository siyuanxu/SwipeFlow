#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NATIVE_DIR="${SWIPEFLOW_NATIVE_DIR:-$REPO_ROOT/.build/NativeRuntime}"
CACHE_DIR="${SWIPEFLOW_NATIVE_CACHE_DIR:-$REPO_ROOT/.build/NativeDeps}"
PREFIX_DIR="$NATIVE_DIR/prefix"
PACKAGE_DIR="$NATIVE_DIR/package"
LIB_DIR="$PACKAGE_DIR/lib"
INCLUDE_DIR="$PACKAGE_DIR/include"
LICENSE_DIR="$PACKAGE_DIR/licenses"
PKGCONFIG_DIR="$LIB_DIR/pkgconfig"

mkdir -p "$LIB_DIR" "$INCLUDE_DIR/mpv" "$LICENSE_DIR/runtime" \
    "$LICENSE_DIR/build-only" "$PKGCONFIG_DIR"

libraries=(
    libmpv.2.dylib
    libass.9.dylib
    libavcodec.62.dylib
    libavfilter.11.dylib
    libavformat.62.dylib
    libavutil.60.dylib
    libplacebo.360.dylib
    libswresample.6.dylib
    libswscale.9.dylib
    libfreetype.6.dylib
    libfribidi.0.dylib
    libharfbuzz.0.dylib
)

for name in "${libraries[@]}"; do
    cp -L "$PREFIX_DIR/lib/$name" "$LIB_DIR/$name"
done
ln -sfn libmpv.2.dylib "$LIB_DIR/libmpv.dylib"
cp "$PREFIX_DIR/include/mpv/"*.h "$INCLUDE_DIR/mpv/"
sed \
    -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' \
    -e '/^Requires\.private:/d' \
    -e '/^Libs\.private:/d' \
    "$PREFIX_DIR/lib/pkgconfig/mpv.pc" > "$PKGCONFIG_DIR/mpv.pc"

for name in "${libraries[@]}"; do
    library="$LIB_DIR/$name"
    install_name_tool -id "@rpath/$name" "$library"
    while IFS= read -r dependency; do
        case "$dependency" in
            "$PREFIX_DIR"/lib/*)
                install_name_tool -change "$dependency" \
                    "@rpath/$(basename "$dependency")" "$library"
                ;;
        esac
    done < <(otool -L "$library" | tail -n +2 | awk '{print $1}')
done

SOURCE_DIR="$CACHE_DIR/sources"
cp "$SOURCE_DIR/mpv-0.41.0/Copyright" "$LICENSE_DIR/runtime/mpv-Copyright.txt"
cp "$SOURCE_DIR/ffmpeg-8.1.2/COPYING.LGPLv2.1" "$LICENSE_DIR/runtime/FFmpeg-LGPL-2.1.txt"
cp "$SOURCE_DIR/libplacebo-v7.360.1/LICENSE" "$LICENSE_DIR/runtime/libplacebo-LGPL-2.1.txt"
cp "$SOURCE_DIR/libass-0.17.5/COPYING" "$LICENSE_DIR/runtime/libass-ISC.txt"
cp "$SOURCE_DIR/freetype-2.14.3/LICENSE.TXT" "$LICENSE_DIR/runtime/FreeType-License.txt"
cp "$SOURCE_DIR/fribidi-1.0.16/COPYING" "$LICENSE_DIR/runtime/FriBidi-LGPL-2.1.txt"
cp "$SOURCE_DIR/harfbuzz-14.2.1/COPYING" "$LICENSE_DIR/runtime/HarfBuzz-Copyright.txt"
cp "$SOURCE_DIR/Vulkan-Headers-1.4.350.1/LICENSE.md" "$LICENSE_DIR/build-only/Vulkan-Headers-Apache-2.0.txt"
cp "$SOURCE_DIR/libplacebo-v7.360.1/3rdparty/glad/LICENSE" "$LICENSE_DIR/build-only/glad-License.txt"
cp "$SOURCE_DIR/libplacebo-v7.360.1/3rdparty/jinja/LICENSE.txt" "$LICENSE_DIR/build-only/Jinja-License.txt"
cp "$SOURCE_DIR/libplacebo-v7.360.1/3rdparty/markupsafe/LICENSE.txt" "$LICENSE_DIR/build-only/MarkupSafe-License.txt"
cp "$SOURCE_DIR/libplacebo-v7.360.1/3rdparty/fast_float/LICENSE-MIT" "$LICENSE_DIR/build-only/fast_float-MIT.txt"

(
    cd "$CACHE_DIR/downloads"
    shasum -a 256 \
        mpv-v0.41.0.tar.gz ffmpeg-8.1.2.tar.xz \
        libplacebo-v7.360.1.tar.bz2 libass-0.17.5.tar.xz \
        freetype-2.14.3.tar.xz fribidi-1.0.16.tar.xz \
        harfbuzz-14.2.1.tar.xz glad2-2.0.8.tar.gz \
        jinja2-3.1.6.tar.gz markupsafe-3.0.3.tar.gz \
        fast_float-8.2.10.tar.gz Vulkan-Headers-1.4.350.1.tar.gz \
        > "$PACKAGE_DIR/SOURCE_MANIFEST.sha256"
)

echo "Packaged native runtime: $PACKAGE_DIR"
