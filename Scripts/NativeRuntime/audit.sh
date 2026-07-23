#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NATIVE_DIR="${SWIPEFLOW_NATIVE_DIR:-$REPO_ROOT/.build/NativeRuntime}"
PACKAGE_DIR="$NATIVE_DIR/package"
LIB_DIR="$PACKAGE_DIR/lib"
METADATA_DIR="$NATIVE_DIR/metadata"
failures=0

fail() {
    echo "AUDIT FAILURE: $*" >&2
    failures=$((failures + 1))
}

expected=(
    libmpv.2.dylib libass.9.dylib libavcodec.62.dylib
    libavfilter.11.dylib libavformat.62.dylib libavutil.60.dylib
    libplacebo.360.dylib libswresample.6.dylib libswscale.9.dylib
    libfreetype.6.dylib libfribidi.0.dylib libharfbuzz.0.dylib
)

for name in "${expected[@]}"; do
    library="$LIB_DIR/$name"
    if [[ ! -f "$library" ]]; then
        fail "Missing $name"
        continue
    fi
    if ! file "$library" | grep -q 'arm64'; then
        fail "$name is not arm64"
    fi
    identifier="$(otool -D "$library" | tail -1)"
    if [[ "$identifier" != "@rpath/$name" ]]; then
        fail "$name has unexpected install id: $identifier"
    fi
    minos="$(otool -l "$library" | awk '/LC_BUILD_VERSION/{seen=1} seen && /minos/{print $2; exit}')"
    if [[ -z "$minos" || "$minos" != 14.0 ]]; then
        fail "$name has unexpected minimum macOS version: ${minos:-missing}"
    fi
    while IFS= read -r dependency; do
        case "$dependency" in
            @rpath/*|/usr/lib/*|/System/Library/*) ;;
            *) fail "$name has non-bundle dependency: $dependency" ;;
        esac
        if [[ "$dependency" == @rpath/* ]]; then
            bundled="${dependency#@rpath/}"
            [[ -f "$LIB_DIR/$bundled" ]] || fail "$name references missing $bundled"
        fi
    done < <(otool -L "$library" | tail -n +2 | awk '{print $1}')
    if grep -aE '/Users/[^/[:cntrl:]]+' "$library" >/dev/null; then
        fail "$name contains a developer home-directory path"
    fi
done

if otool -L "$LIB_DIR/"*.dylib | awk '/^\t/{print $1}' | \
    grep -E '/opt/homebrew|/usr/local|/Users/' >/dev/null; then
    fail "A developer-machine path remains in the packaged dependency graph"
fi

if [[ -f "$METADATA_DIR/ffmpeg-config.h" ]]; then
    grep -q '^#define CONFIG_GPL 0$' "$METADATA_DIR/ffmpeg-config.h" || fail "FFmpeg GPL is not disabled"
    grep -q '^#define CONFIG_NONFREE 0$' "$METADATA_DIR/ffmpeg-config.h" || fail "FFmpeg nonfree is not disabled"
    grep -q '^#define CONFIG_VERSION3 0$' "$METADATA_DIR/ffmpeg-config.h" || fail "FFmpeg version3 is not disabled"
else
    fail "Missing recorded FFmpeg configuration"
fi

if [[ -f "$METADATA_DIR/mpv-build-options.txt" ]]; then
    grep -Eq '^  gpl[[:space:]]+false' "$METADATA_DIR/mpv-build-options.txt" || fail "mpv GPL is not disabled"
    grep -Eq '^  cplayer[[:space:]]+false' "$METADATA_DIR/mpv-build-options.txt" || fail "mpv CLI player is not disabled"
    grep -Eq '^  libmpv[[:space:]]+true' "$METADATA_DIR/mpv-build-options.txt" || fail "libmpv is not enabled"
else
    fail "Missing recorded mpv build options"
fi

if [[ "$failures" -ne 0 ]]; then
    echo "Native runtime audit failed with $failures issue(s)." >&2
    exit 1
fi

echo "Native runtime audit passed: ${#expected[@]} arm64 dylibs, macOS 14.0, relative runtime graph, LGPL profile."
