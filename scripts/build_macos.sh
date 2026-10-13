#!/bin/bash
set -euo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$WORK_DIR/webrtc/src"
export PATH="$WORK_DIR/webrtc/depot_tools:$PATH"

ARCHS=("${@:-x64}")

BUILD_CONFIG=${BUILD_CONFIG:-debug}

# Shared build state is populated by the initialization and per-architecture steps.
cleanup() {
    rm -f "$METADATA"
    [ -z "$STAGE" ] || rm -rf "$STAGE"
    return 0
}

initialize_build() {
    case "$BUILD_CONFIG" in
        release) IS_DEBUG=false ;;
        debug) IS_DEBUG=true ;;
        *) echo "Invalid BUILD_CONFIG: $BUILD_CONFIG" >&2; exit 1 ;;
    esac

    [ -d "$SRC_DIR" ] || { echo "Run prepare_webrtc_src.sh first." >&2; exit 1; }
    cd "$SRC_DIR"
    METADATA=$(mktemp)
    STAGE=''
    trap cleanup EXIT
    python3 "$WORK_DIR/scripts/lib/build_info.py" capture "$METADATA" "$WORK_DIR" "$BUILD_CONFIG"
}

FRAMEWORKS=()
BINARIES=()
DSYMS=()
SYMBOLS=()
# Framework preparation is shared by every architecture.
prepare_headers() {
    local HEADERS_DIR="$1/Versions/A/Headers"
    mkdir -p "$HEADERS_DIR"
    find "$SRC_DIR/sdk/objc" -name "RTC*.h" -exec cp {} "$HEADERS_DIR/" \;
    find "$HEADERS_DIR" -name "*.h" -exec sed -i '' \
        's|#import "sdk/objc/base/\(.*\)"|#import <WebRTC/\1>|g' {} \; -exec sed -i '' \
        's|#import "sdk/objc/api/peerconnection/\(.*\)"|#import <WebRTC/\1>|g' {} \; -exec sed -i '' \
        's|#import "sdk/objc/\(.*\)"|#import <WebRTC/\1>|g' {} \;
}

embed_build_info() {
    local framework="$1"
    shift
    python3 "$WORK_DIR/scripts/lib/build_info.py" embed "$framework" \
        "$METADATA" "$WORK_DIR" macos "$@"
}

build_architecture() {
    local arch="$1"
    local OUT_DIR dsym candidate
    OUT_DIR="out/macos-$arch"
    echo "=== Building WebRTC for macOS $arch ($BUILD_CONFIG) ==="
    gn gen "$OUT_DIR" --args="target_cpu=\"$arch\" target_os=\"mac\" is_debug=$IS_DEBUG symbol_level=2 enable_dsyms=true rtc_libvpx_build_vp9=true is_component_build=false rtc_include_tests=false rtc_enable_objc_symbol_export=true enable_stripping=false"
    ninja -C "$OUT_DIR" mac_framework_objc
    prepare_headers "$SRC_DIR/$OUT_DIR/WebRTC.framework"
    embed_build_info "$SRC_DIR/$OUT_DIR/WebRTC.framework" "$arch"
    FRAMEWORKS+=("$SRC_DIR/$OUT_DIR/WebRTC.framework")
    BINARIES+=("$SRC_DIR/$OUT_DIR/WebRTC.framework/WebRTC")
    # GN versions differ in their dSYM naming.
    dsym=""
    for candidate in "$SRC_DIR/$OUT_DIR/WebRTC.framework.dSYM" "$SRC_DIR/$OUT_DIR/WebRTC.dSYM"; do
        [ -d "$candidate" ] || continue
        dsym="$candidate"
        break
    done
    if [ -n "$dsym" ]; then
        DSYMS+=("$dsym")
        SYMBOLS+=("$dsym/Contents/Resources/DWARF/WebRTC")
    fi
}

merge_frameworks() {
    local DEST BINARY
    # xcodebuild accepts one framework per platform, so merge macOS first.
    DEST="$SRC_DIR/out/macos-universal"
    mkdir -p "$DEST"
    STAGE=$(mktemp -d "$SRC_DIR/out/.macos-merge.XXXXXX")
    ditto "${FRAMEWORKS[0]}" "$STAGE/WebRTC.framework"
    BINARY=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$STAGE/WebRTC.framework/WebRTC")
    lipo -create "${BINARIES[@]}" -output "$BINARY"

    if [ "${#DSYMS[@]}" -eq "${#ARCHS[@]}" ]; then
        ditto "${DSYMS[0]}" "$STAGE/WebRTC.framework.dSYM"
        lipo -create "${SYMBOLS[@]}" \
            -output "$STAGE/WebRTC.framework.dSYM/Contents/Resources/DWARF/WebRTC"
    elif [ "${#DSYMS[@]}" -gt 0 ]; then
        echo "Error: a dSYM is missing for one macOS architecture." >&2; exit 1
    fi

    embed_build_info "$STAGE/WebRTC.framework" "${ARCHS[@]}"
    # Replace generated bundles only after merging succeeds.
    rm -rf "$DEST/WebRTC.framework" "$DEST/WebRTC.framework.dSYM" "$DEST/WebRTC.dSYM"
    mv "$STAGE/WebRTC.framework" "$DEST/"
    [ ! -d "$STAGE/WebRTC.framework.dSYM" ] || mv "$STAGE/WebRTC.framework.dSYM" "$DEST/"
    echo "Universal macOS framework: $DEST/WebRTC.framework"
}

main() {
    local arch
    initialize_build
    for arch in "${ARCHS[@]}"; do
        build_architecture "$arch"
    done
    if [ "${#ARCHS[@]}" -gt 1 ]; then
        merge_frameworks
    else
        echo "macOS framework: ${FRAMEWORKS[0]}"
    fi
}

main
