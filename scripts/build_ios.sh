#!/bin/bash
set -e

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$WORK_DIR/webrtc/src"
OUTPUT_DIR="$SRC_DIR/out/ios"
ARTIFACTS_DIR="$WORK_DIR/artifacts/WebRTC_iOS/"

export PATH="$WORK_DIR/depot_tools:$PATH"

if [ ! -d "$SRC_DIR" ]; then
    echo "Error: WebRTC source not found. Run prepare_webrtc_src.sh first."
    exit 1
fi

cd "$SRC_DIR"

echo "=== Building WebRTC for iOS (Device & Simulator) ==="
# WebRTC's official build utility handles device/simulator compilation and packaging
./tools_webrtc/ios/build_ios_libs.sh \
    -o "$OUTPUT_DIR/" \
    --build_config release \
    --arch {device:arm64,simulator:x64,simulator:arm64}

echo "iOS build completed! XCFramework and dSYMs are located at:"
echo "$OUTPUT_DIR"
