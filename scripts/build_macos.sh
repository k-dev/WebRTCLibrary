#!/bin/bash
set -euo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$WORK_DIR/webrtc/src"
export PATH="$WORK_DIR/webrtc/depot_tools:$PATH"

# No arguments keeps the original x64, debug build in out/macos.
LEGACY=false
ARCHS=("$@")
if [ "$#" -eq 0 ]; then
    ARCHS=(x64)
    LEGACY=true
fi
BUILD_CONFIG=${BUILD_CONFIG:-debug}
case "$BUILD_CONFIG" in
    release) IS_DEBUG=false ;;
    debug) IS_DEBUG=true ;;
    *) echo "Invalid BUILD_CONFIG: $BUILD_CONFIG" >&2; exit 1 ;;
esac
for arch in "${ARCHS[@]}"; do
    case "$arch" in arm64|x64) ;; *) echo "Usage: $0 [arm64] [x64]" >&2; exit 1 ;; esac
done
[ "${#ARCHS[@]}" -le 2 ] || { echo "Select at most two architectures." >&2; exit 1; }
if [ "${#ARCHS[@]}" -eq 2 ] && [ "${ARCHS[0]}" = "${ARCHS[1]}" ]; then
    echo "Duplicate architecture." >&2; exit 1
fi
[ -d "$SRC_DIR" ] || { echo "Run prepare_webrtc_src.sh first." >&2; exit 1; }
cd "$SRC_DIR"

FRAMEWORKS=()
DSYMS=()
for arch in "${ARCHS[@]}"; do
    OUT_DIR="out/macos-$arch"
    if $LEGACY; then OUT_DIR="out/macos"; fi
    echo "=== Building WebRTC for macOS $arch ($BUILD_CONFIG) ==="
    gn gen "$OUT_DIR" --args="target_cpu=\"$arch\" target_os=\"mac\" is_debug=$IS_DEBUG symbol_level=2 enable_dsyms=true rtc_libvpx_build_vp9=true is_component_build=false rtc_include_tests=false rtc_enable_objc_symbol_export=true enable_stripping=false"
    ninja -C "$OUT_DIR" mac_framework_objc
    FRAMEWORKS+=("$SRC_DIR/$OUT_DIR/WebRTC.framework")
    # GN versions differ in their dSYM naming.
    dsym=""
    for candidate in "$SRC_DIR/$OUT_DIR/WebRTC.framework.dSYM" "$SRC_DIR/$OUT_DIR/WebRTC.dSYM"; do
        if [ -d "$candidate" ]; then dsym="$candidate"; break; fi
    done
    DSYMS+=("$dsym")
done

if [ "${#ARCHS[@]}" -eq 2 ]; then
    # xcodebuild accepts one framework per platform, so merge macOS first.
    DEST="$SRC_DIR/out/macos-universal"
    mkdir -p "$DEST"
    STAGE=$(mktemp -d "$SRC_DIR/out/.macos-merge.XXXXXX")
    trap 'rm -rf "$STAGE"' EXIT
    ditto "${FRAMEWORKS[0]}" "$STAGE/WebRTC.framework"
    BINARY=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$STAGE/WebRTC.framework/WebRTC")
    lipo -create "${FRAMEWORKS[0]}/WebRTC" "${FRAMEWORKS[1]}/WebRTC" -output "$BINARY"
    if [ -n "${DSYMS[0]}" ] && [ -n "${DSYMS[1]}" ]; then
        ditto "${DSYMS[0]}" "$STAGE/WebRTC.framework.dSYM"
        lipo -create "${DSYMS[0]}/Contents/Resources/DWARF/WebRTC" "${DSYMS[1]}/Contents/Resources/DWARF/WebRTC" \
            -output "$STAGE/WebRTC.framework.dSYM/Contents/Resources/DWARF/WebRTC"
    elif [ -n "${DSYMS[0]}${DSYMS[1]}" ]; then
        echo "Error: a dSYM is missing for one macOS architecture." >&2; exit 1
    fi
    # Replace generated bundles only after merging succeeds.
    rm -rf "$DEST/WebRTC.framework" "$DEST/WebRTC.framework.dSYM" "$DEST/WebRTC.dSYM"
    mv "$STAGE/WebRTC.framework" "$DEST/"
    if [ -d "$STAGE/WebRTC.framework.dSYM" ]; then mv "$STAGE/WebRTC.framework.dSYM" "$DEST/"; fi
    echo "Universal macOS framework: $DEST/WebRTC.framework"
else
    echo "macOS framework: ${FRAMEWORKS[0]}"
fi
