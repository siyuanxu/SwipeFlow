#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NATIVE_DIR="${SWIPEFLOW_NATIVE_DIR:-$REPO_ROOT/.build/NativeRuntime}"
PACKAGE_DIR="$NATIVE_DIR/package"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swipeflow-runtime-smoke.XXXXXX")"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/lib"
cp "$PACKAGE_DIR/lib/"*.dylib "$WORK_DIR/lib/"

xcrun clang \
    -mmacosx-version-min=14.0 \
    -I "$PACKAGE_DIR/include" \
    "$SCRIPT_DIR/smoke.c" \
    "$PACKAGE_DIR/lib/libmpv.2.dylib" \
    -Wl,-rpath,@executable_path/lib \
    -o "$WORK_DIR/swipeflow-runtime-smoke"

"$WORK_DIR/swipeflow-runtime-smoke"
