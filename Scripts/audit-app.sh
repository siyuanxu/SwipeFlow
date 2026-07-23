#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="${1:-$REPO_ROOT/.build/XcodeDerivedData/Build/Products/Release/SwipeFlow.app}"
EXECUTABLE="$APP_PATH/Contents/MacOS/SwipeFlow"
FRAMEWORKS="$APP_PATH/Contents/Frameworks"
RESOURCES="$APP_PATH/Contents/Resources"
NOTICES="$RESOURCES/NativeRuntime"

expected=(
    libmpv.2.dylib libass.9.dylib libavcodec.62.dylib
    libavfilter.11.dylib libavformat.62.dylib libavutil.60.dylib
    libplacebo.360.dylib libswresample.6.dylib libswscale.9.dylib
    libfreetype.6.dylib libfribidi.0.dylib libharfbuzz.0.dylib
)

[[ -x "$EXECUTABLE" ]] || { echo "Missing SwipeFlow executable." >&2; exit 1; }
for name in "${expected[@]}"; do
    [[ -f "$FRAMEWORKS/$name" ]] || { echo "Missing embedded $name." >&2; exit 1; }
done

embedded_count="$(find "$FRAMEWORKS" -maxdepth 1 -type f -name '*.dylib' | wc -l | tr -d ' ')"
[[ "$embedded_count" == "${#expected[@]}" ]] || {
    echo "Expected ${#expected[@]} embedded dylibs, found $embedded_count." >&2
    exit 1
}

[[ -f "$RESOURCES/Licenses/SwipeFlow-MIT.txt" ]] || {
    echo "Missing SwipeFlow MIT license." >&2
    exit 1
}
[[ -f "$NOTICES/README.md" && -f "$NOTICES/SOURCE_MANIFEST.sha256" ]] || {
    echo "Missing native runtime source or replacement notice." >&2
    exit 1
}
runtime_license_count="$(find "$NOTICES/Licenses" -type f | wc -l | tr -d ' ')"
[[ "$runtime_license_count" -ge 12 ]] || {
    echo "Expected native runtime license notices, found $runtime_license_count." >&2
    exit 1
}

otool -l "$EXECUTABLE" | awk '
    /LC_RPATH/ { in_rpath = 1; next }
    in_rpath && /path @executable_path\/\.\.\/Frameworks/ { found = 1 }
    in_rpath && /path/ { in_rpath = 0 }
    END { exit found ? 0 : 1 }
' || { echo "App is missing the Frameworks runtime search path." >&2; exit 1; }

if otool -L "$EXECUTABLE" "$FRAMEWORKS/"*.dylib | \
    awk '/^\t/{print $1}' | grep -E '/opt/homebrew|/usr/local|/Users/' >/dev/null; then
    echo "A developer-machine path remains in the app dependency graph." >&2
    exit 1
fi

for binary in "$EXECUTABLE" "$FRAMEWORKS/"*.dylib; do
    if grep -aE '/Users/[^/[:cntrl:]]+' "$binary" >/dev/null; then
        echo "A developer home-directory path remains embedded in $(basename "$binary")." >&2
        exit 1
    fi
done

codesign --verify --deep --strict "$APP_PATH"
codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | \
    grep -q 'com.apple.security.cs.disable-library-validation' || {
        echo "Ad-hoc app is missing its library-validation entitlement." >&2
        exit 1
    }
echo "SwipeFlow app audit passed: 12 embedded dylibs, licenses, relative runtime graph, valid signature."
