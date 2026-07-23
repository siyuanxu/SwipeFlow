#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="${SWIPEFLOW_RUNTIME_PACKAGE_DIR:-$REPO_ROOT/.build/NativeRuntime/package}"
CONFIGURATION="${SWIPEFLOW_CONFIGURATION:-Release}"

if [[ ! -f "$RUNTIME_DIR/lib/libmpv.2.dylib" ]]; then
    echo "Native runtime is missing. Run Scripts/NativeRuntime/build.sh first." >&2
    exit 1
fi

export PKG_CONFIG_PATH="$RUNTIME_DIR/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$RUNTIME_DIR/lib/pkgconfig"
export SWIPEFLOW_RUNTIME_PACKAGE_DIR="$RUNTIME_DIR"
export CLANG_MODULE_CACHE_PATH="$REPO_ROOT/.build/XcodeModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$REPO_ROOT/.build/XcodeModuleCache"

cd "$REPO_ROOT"
xcodebuild \
    -project SwipeFlow.xcodeproj \
    -scheme SwipeFlow \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath .build/XcodeDerivedData \
    CODE_SIGNING_ALLOWED=YES \
    build

APP_PATH="$REPO_ROOT/.build/XcodeDerivedData/Build/Products/$CONFIGURATION/SwipeFlow.app"
strip -S "$APP_PATH/Contents/MacOS/SwipeFlow"
codesign --force --sign - --timestamp=none \
    --entitlements "$REPO_ROOT/App/SwipeFlow.entitlements" \
    "$APP_PATH"

"$SCRIPT_DIR/audit-app.sh" "$APP_PATH"
