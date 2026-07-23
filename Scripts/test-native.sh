#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.build/NativeRuntime/package"

if [[ ! -f "$RUNTIME_DIR/lib/libmpv.2.dylib" ]]; then
    echo "Native runtime is missing. Run Scripts/NativeRuntime/build.sh first." >&2
    exit 1
fi

export PKG_CONFIG_PATH="$RUNTIME_DIR/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$RUNTIME_DIR/lib/pkgconfig"
export CLANG_MODULE_CACHE_PATH="$REPO_ROOT/.build/NativeModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$REPO_ROOT/.build/NativeModuleCache"

cd "$REPO_ROOT"
swift build \
    --build-tests \
    --disable-sandbox \
    --package-path NativePlayback \
    --scratch-path .build/NativePlaybackPackaged

BIN_DIR="$(swift build \
    --disable-sandbox \
    --package-path NativePlayback \
    --scratch-path .build/NativePlaybackPackaged \
    --show-bin-path)"
cp "$RUNTIME_DIR/lib/"lib*.*.dylib "$BIN_DIR/"

swift test \
    --skip-build \
    --disable-sandbox \
    --package-path NativePlayback \
    --scratch-path .build/NativePlaybackPackaged
