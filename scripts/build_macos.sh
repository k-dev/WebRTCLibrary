#!/bin/bash
set -e

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$WORK_DIR/webrtc/src"
ARTIFACTS_DIR="$WORK_DIR/artifacts/WebRTC_Mac"
OUT_DIR="out/macos"

export PATH="$WORK_DIR/webrtc/depot_tools:$PATH"

if [ ! -d "$SRC_DIR" ]; then
    echo "Error: WebRTC source not found. Run prepare_webrtc_src.sh first."
    exit 1
fi

cd "$SRC_DIR"

echo "=== Generating GN build configuration for macOS ==="
gn gen $OUT_DIR --args="target_cpu=\"x64\" target_os=\"mac\" is_debug=true symbol_level=2 enable_dsyms=true rtc_libvpx_build_vp9=true is_component_build=false rtc_include_tests=false rtc_enable_objc_symbol_export=true enable_stripping=false"

echo "Compiling WebRTC macOS framework..."
ninja -C $OUT_DIR mac_framework_objc

echo "Created macOS framework at $SRC_DIR/$OUT_DIR/WebRTC.framework"

# echo "Creating macOS XCFramework (with dSYMs)..."
# mkdir -p "$ARTIFACTS_DIR"
# rm -rf "$ARTIFACTS_DIR/WebRTC.xcframework"

# # Use Xcode's tool to wrap the framework and its dSYM into a valid .xcframework
# XCFRAMEWORK_ARGS=(
#     -framework "$OUT_DIR/WebRTC.framework"
# )

# if [ -d "$OUT_DIR/WebRTC.dSYM" ]; then
#     XCFRAMEWORK_ARGS+=(-debug-symbols "$OUT_DIR/WebRTC.dSYM")
# fi

# xcodebuild -create-xcframework \
#     "${XCFRAMEWORK_ARGS[@]}" \
#     -output "$ARTIFACTS_DIR/WebRTC.xcframework"

# echo "macOS build completed! XCFramework is located at:"
# echo "$ARTIFACTS_DIR/WebRTC.xcframework"
