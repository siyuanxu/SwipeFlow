#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

NATIVE_DIR="${SWIPEFLOW_NATIVE_DIR:-$REPO_ROOT/.build/NativeRuntime}"
CACHE_DIR="${SWIPEFLOW_NATIVE_CACHE_DIR:-$REPO_ROOT/.build/NativeDeps}"
DOWNLOAD_DIR="$CACHE_DIR/downloads"
SOURCE_DIR="$CACHE_DIR/sources"
BUILD_DIR="$NATIVE_DIR/work"
PREFIX_DIR="$NATIVE_DIR/prefix"
METADATA_DIR="$NATIVE_DIR/metadata"
DEPLOYMENT_TARGET=14.0
JOBS="${SWIPEFLOW_NATIVE_JOBS:-8}"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "This profile currently supports arm64 macOS only." >&2
    exit 1
fi

for tool in curl shasum tar meson ninja pkg-config make xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing build tool: $tool" >&2
        exit 1
    fi
done

MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$DOWNLOAD_DIR" "$SOURCE_DIR" "$BUILD_DIR" "$PREFIX_DIR" "$METADATA_DIR"

download() {
    local archive="$1"
    local url="$2"
    local expected="$3"
    local destination="$DOWNLOAD_DIR/$archive"
    local actual

    if [[ ! -f "$destination" ]]; then
        curl --fail --location --output "$destination" "$url"
    fi
    actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "SHA-256 mismatch for $archive" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

extract() {
    local archive="$1"
    local destination="$2"
    local marker="$destination/.swipeflow-source-$archive"

    if [[ -f "$marker" ]]; then
        return
    fi
    mkdir -p "$destination"
    if [[ -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        tar -xf "$DOWNLOAD_DIR/$archive" --strip-components=1 -C "$destination"
    fi
    touch "$marker"
}

download "$MPV_ARCHIVE" "$MPV_URL" "$MPV_SHA256"
download "$FFMPEG_ARCHIVE" "$FFMPEG_URL" "$FFMPEG_SHA256"
download "$LIBPLACEBO_ARCHIVE" "$LIBPLACEBO_URL" "$LIBPLACEBO_SHA256"
download "$LIBASS_ARCHIVE" "$LIBASS_URL" "$LIBASS_SHA256"
download "$FREETYPE_ARCHIVE" "$FREETYPE_URL" "$FREETYPE_SHA256"
download "$FRIBIDI_ARCHIVE" "$FRIBIDI_URL" "$FRIBIDI_SHA256"
download "$HARFBUZZ_ARCHIVE" "$HARFBUZZ_URL" "$HARFBUZZ_SHA256"
download "$GLAD_ARCHIVE" "$GLAD_URL" "$GLAD_SHA256"
download "$JINJA_ARCHIVE" "$JINJA_URL" "$JINJA_SHA256"
download "$MARKUPSAFE_ARCHIVE" "$MARKUPSAFE_URL" "$MARKUPSAFE_SHA256"
download "$FAST_FLOAT_ARCHIVE" "$FAST_FLOAT_URL" "$FAST_FLOAT_SHA256"
download "$VULKAN_HEADERS_ARCHIVE" "$VULKAN_HEADERS_URL" "$VULKAN_HEADERS_SHA256"

MPV_SOURCE="$SOURCE_DIR/mpv-$MPV_VERSION"
FFMPEG_SOURCE="$SOURCE_DIR/ffmpeg-$FFMPEG_VERSION"
LIBPLACEBO_SOURCE="$SOURCE_DIR/libplacebo-v$LIBPLACEBO_VERSION"
LIBASS_SOURCE="$SOURCE_DIR/libass-$LIBASS_VERSION"
FREETYPE_SOURCE="$SOURCE_DIR/freetype-$FREETYPE_VERSION"
FRIBIDI_SOURCE="$SOURCE_DIR/fribidi-$FRIBIDI_VERSION"
HARFBUZZ_SOURCE="$SOURCE_DIR/harfbuzz-$HARFBUZZ_VERSION"
VULKAN_HEADERS_SOURCE="$SOURCE_DIR/Vulkan-Headers-$VULKAN_HEADERS_VERSION"

extract "$MPV_ARCHIVE" "$MPV_SOURCE"
extract "$FFMPEG_ARCHIVE" "$FFMPEG_SOURCE"
extract "$LIBPLACEBO_ARCHIVE" "$LIBPLACEBO_SOURCE"
extract "$LIBASS_ARCHIVE" "$LIBASS_SOURCE"
extract "$FREETYPE_ARCHIVE" "$FREETYPE_SOURCE"
extract "$FRIBIDI_ARCHIVE" "$FRIBIDI_SOURCE"
extract "$HARFBUZZ_ARCHIVE" "$HARFBUZZ_SOURCE"
extract "$VULKAN_HEADERS_ARCHIVE" "$VULKAN_HEADERS_SOURCE"
extract "$GLAD_ARCHIVE" "$LIBPLACEBO_SOURCE/3rdparty/glad"
extract "$JINJA_ARCHIVE" "$LIBPLACEBO_SOURCE/3rdparty/jinja"
extract "$MARKUPSAFE_ARCHIVE" "$LIBPLACEBO_SOURCE/3rdparty/markupsafe"
extract "$FAST_FLOAT_ARCHIVE" "$LIBPLACEBO_SOURCE/3rdparty/fast_float"

COMMON_ENV=(
    "MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET"
    "SDKROOT=$MACOS_SDK"
    "CFLAGS=-I$PREFIX_DIR/include -isysroot $MACOS_SDK -mmacosx-version-min=$DEPLOYMENT_TARGET"
    "CXXFLAGS=-I$PREFIX_DIR/include -isysroot $MACOS_SDK -mmacosx-version-min=$DEPLOYMENT_TARGET"
    "LDFLAGS=-L$PREFIX_DIR/lib -isysroot $MACOS_SDK -mmacosx-version-min=$DEPLOYMENT_TARGET"
    "PKG_CONFIG_PATH=$PREFIX_DIR/lib/pkgconfig"
    "PKG_CONFIG_LIBDIR=$PREFIX_DIR/lib/pkgconfig"
)

fresh_build_dir() {
    local name="$1"
    local candidate="$BUILD_DIR/$name"
    if [[ -e "$candidate" ]]; then
        candidate="$BUILD_DIR/$name-$(date +%Y%m%d%H%M%S)"
    fi
    mkdir -p "$candidate"
    printf '%s\n' "$candidate"
}

if [[ ! -f "$PREFIX_DIR/lib/libfreetype.6.dylib" ]]; then
    build="$(fresh_build_dir freetype)"
    env "${COMMON_ENV[@]}" meson setup "$build" "$FREETYPE_SOURCE" \
        --prefix="$PREFIX_DIR" --libdir=lib --buildtype=release \
        --default-library=shared --wrap-mode=nofallback \
        -Dzlib=disabled -Dbzip2=disabled -Dpng=disabled -Dbrotli=disabled \
        -Dharfbuzz=disabled -Dtests=disabled -Dmmap=enabled
    meson compile -C "$build"
    meson install -C "$build"
fi

if [[ ! -f "$PREFIX_DIR/lib/libharfbuzz.0.dylib" ]]; then
    build="$(fresh_build_dir harfbuzz)"
    env "${COMMON_ENV[@]}" meson setup "$build" "$HARFBUZZ_SOURCE" \
        --prefix="$PREFIX_DIR" --libdir=lib --buildtype=release \
        --default-library=shared --wrap-mode=nofallback \
        -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
        -Dpng=disabled -Dzlib=disabled -Dicu=disabled -Dgraphite2=disabled \
        -Dfreetype=disabled -Dfontations=disabled -Dcoretext=disabled \
        -Dharfrust=disabled -Dkbts=disabled -Dwasm=disabled \
        -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dsubset=disabled \
        -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled \
        -Dutilities=disabled -Dbenchmark=disabled
    meson compile -C "$build"
    meson install -C "$build"
fi

if [[ ! -f "$PREFIX_DIR/lib/libfribidi.0.dylib" ]]; then
    build="$(fresh_build_dir fribidi)"
    env "${COMMON_ENV[@]}" meson setup "$build" "$FRIBIDI_SOURCE" \
        --prefix="$PREFIX_DIR" --libdir=lib --buildtype=release \
        --default-library=shared --wrap-mode=nofallback \
        -Ddocs=false -Dbin=false -Dtests=false -Ddeprecated=true
    meson compile -C "$build"
    meson install -C "$build"
fi

if [[ ! -f "$PREFIX_DIR/lib/libass.9.dylib" ]]; then
    build="$(fresh_build_dir libass)"
    (
        cd "$build"
        env "${COMMON_ENV[@]}" \
            CC="$(xcrun --find clang)" \
            CPPFLAGS="-I$PREFIX_DIR/include" \
            PKG_CONFIG="$(command -v pkg-config)" \
            "$LIBASS_SOURCE/configure" \
            --prefix="$PREFIX_DIR" --libdir="$PREFIX_DIR/lib" \
            --disable-static --enable-shared --disable-fontconfig \
            --disable-coretext --disable-require-system-font-provider \
            --disable-libunibreak --disable-asm \
            --disable-test --disable-compare --disable-profile --disable-fuzz \
            --disable-dependency-tracking
        make -j "$JOBS"
        make install
    )
fi

if [[ ! -d "$PREFIX_DIR/include/vulkan" ]]; then
    cp -R "$VULKAN_HEADERS_SOURCE/include/vulkan" "$PREFIX_DIR/include/"
    cp -R "$VULKAN_HEADERS_SOURCE/include/vk_video" "$PREFIX_DIR/include/"
fi

if [[ ! -f "$PREFIX_DIR/lib/libplacebo.360.dylib" ]]; then
    build="$(fresh_build_dir libplacebo)"
    env "${COMMON_ENV[@]}" meson setup "$build" "$LIBPLACEBO_SOURCE" \
        --prefix="$PREFIX_DIR" --libdir=lib --buildtype=release \
        --default-library=shared --wrap-mode=nofallback \
        -Dvulkan=disabled -Dopengl=enabled -Dgl-proc-addr=enabled \
        -Dd3d11=disabled -Dglslang=disabled -Dshaderc=disabled \
        -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled \
        -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false \
        -Dunwind=disabled -Dxxhash=disabled
    meson compile -C "$build"
    meson install -C "$build"
fi

if [[ ! -f "$PREFIX_DIR/lib/libavcodec.62.dylib" ]]; then
    build="$(fresh_build_dir ffmpeg)"
    (
        cd "$build"
        env "${COMMON_ENV[@]}" "$FFMPEG_SOURCE/configure" \
            --prefix="$PREFIX_DIR" --libdir="$PREFIX_DIR/lib" \
            --shlibdir="$PREFIX_DIR/lib" --arch=arm64 --target-os=darwin \
            --cc="$(xcrun --find clang)" --pkg-config="$(command -v pkg-config)" \
            --disable-gpl --disable-version3 --disable-nonfree \
            --enable-shared --disable-static --disable-programs --disable-doc \
            --disable-debug --disable-autodetect --enable-network \
            --enable-pthreads --enable-audiotoolbox --enable-videotoolbox \
            --enable-securetransport --enable-pic \
            --extra-cflags="-isysroot $MACOS_SDK -mmacosx-version-min=$DEPLOYMENT_TARGET" \
            --extra-ldflags="-isysroot $MACOS_SDK -mmacosx-version-min=$DEPLOYMENT_TARGET"
        make -j "$JOBS"
        make install
        cp config.h "$METADATA_DIR/ffmpeg-config.h"
        cp ffbuild/config.mak "$METADATA_DIR/ffmpeg-config.mak"
    )
fi

if [[ ! -f "$PREFIX_DIR/lib/libmpv.2.dylib" ]]; then
    build="$(fresh_build_dir mpv)"
    env "${COMMON_ENV[@]}" meson setup "$build" "$MPV_SOURCE" \
        --prefix="$PREFIX_DIR" --libdir=lib --buildtype=release \
        --default-library=shared --wrap-mode=nofallback \
        -Dauto_features=disabled -Dgpl=false -Dcplayer=false -Dlibmpv=true \
        -Dbuild-date=false -Dtests=false -Dfuzzers=false \
        -Dgl=enabled -Dplain-gl=enabled -Dcocoa=disabled -Dgl-cocoa=disabled \
        -Dcoreaudio=enabled -Dvideotoolbox-gl=disabled \
        -Dvulkan=disabled -Dvideotoolbox-pl=disabled -Dlibavdevice=disabled \
        -Dmacos-cocoa-cb=disabled -Dswift-build=disabled \
        -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled
    meson compile -C "$build"
    meson install -C "$build"
    meson configure "$build" > "$METADATA_DIR/mpv-build-options.txt"
fi

if [[ ! -f "$METADATA_DIR/ffmpeg-config.h" ]]; then
    ffmpeg_config="$(find "$NATIVE_DIR" -path '*/ffmpeg*/config.h' -type f -print | tail -1)"
    [[ -n "$ffmpeg_config" ]] && cp "$ffmpeg_config" "$METADATA_DIR/ffmpeg-config.h"
fi
if [[ ! -f "$METADATA_DIR/ffmpeg-config.mak" ]]; then
    ffmpeg_config_mak="$(find "$NATIVE_DIR" -path '*/ffmpeg*/ffbuild/config.mak' -type f -print | tail -1)"
    [[ -n "$ffmpeg_config_mak" ]] && cp "$ffmpeg_config_mak" "$METADATA_DIR/ffmpeg-config.mak"
fi
if [[ ! -f "$METADATA_DIR/mpv-build-options.txt" ]]; then
    mpv_build="$(find "$NATIVE_DIR" -path '*/mpv*/meson-private/coredata.dat' -type f -print | tail -1 | xargs -I{} dirname "{}" | xargs -I{} dirname "{}")"
    [[ -n "$mpv_build" ]] && meson configure "$mpv_build" > "$METADATA_DIR/mpv-build-options.txt"
fi

"$SCRIPT_DIR/package.sh"
"$SCRIPT_DIR/audit.sh"
"$SCRIPT_DIR/smoke.sh"
