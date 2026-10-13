#!/bin/bash
set -e

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$WORK_DIR/webrtc/src"
OUTPUT_DIR="$SRC_DIR/out/ios"
ARTIFACTS_DIR="$WORK_DIR/artifacts/WebRTC_iOS/"

export PATH="$WORK_DIR/webrtc/depot_tools:$PATH"

# No arguments retains the original device + both simulator build.
ARCHS=("$@")
if [ "$#" -eq 0 ]; then
    ARCHS=(device:arm64 simulator:x64 simulator:arm64)
fi
for arch in "${ARCHS[@]}"; do
    case "$arch" in
        device:arm64|simulator:x64|simulator:arm64) ;;
        *) echo "Usage: $0 [device:arm64] [simulator:x64] [simulator:arm64]" >&2; exit 1 ;;
    esac
done
BUILD_CONFIG=${BUILD_CONFIG:-release}
case "$BUILD_CONFIG" in release|debug) ;; *) echo "Invalid BUILD_CONFIG" >&2; exit 1 ;; esac

if [ ! -d "$SRC_DIR" ]; then
    echo "Error: WebRTC source not found. Run prepare_webrtc_src.sh first."
    exit 1
fi

cd "$SRC_DIR"
METADATA=$(mktemp)
trap 'rm -f "$METADATA"' EXIT
python3 "$WORK_DIR/scripts/lib/build_info.py" capture "$METADATA" "$WORK_DIR" "$BUILD_CONFIG"

echo "=== Building WebRTC for iOS (Device & Simulator) ==="
# WebRTC's official build utility handles device/simulator compilation and packaging
./tools_webrtc/ios/build_ios_libs.sh \
    -o "$OUTPUT_DIR/" \
    --build_config "$BUILD_CONFIG" \
    --arch "${ARCHS[@]}"

for platform in device simulator; do
    BUILT_ARCHS=()
    for arch in "${ARCHS[@]}"; do
        if [ "${arch%%:*}" = "$platform" ]; then BUILT_ARCHS+=("${arch#*:}"); fi
    done
    if [ "${#BUILT_ARCHS[@]}" -gt 0 ]; then
        python3 "$WORK_DIR/scripts/lib/build_info.py" embed "$OUTPUT_DIR/$platform/WebRTC.framework" \
            "$METADATA" "$WORK_DIR" "ios-$platform" "${BUILT_ARCHS[@]}"
    fi
done

echo "iOS build completed! XCFramework and dSYMs are located at:"
echo "$OUTPUT_DIR"
