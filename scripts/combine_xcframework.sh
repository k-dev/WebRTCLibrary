#!/bin/bash
set -e

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$WORK_DIR/webrtc/src/out"
OUTPUT_DIR="$WORK_DIR/artifacts"
OUTPUT_PATH="$OUTPUT_DIR/WebRTC.xcframework"

# Example usage:
# ./scripts/combine_xcframework.sh ios/device ios/simulator macos-x64

# Require at least one directory.
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <Directory1> [Directory2 ...]"
    echo "Example: \"$0 ios/device macos\""
    exit 1
fi

XCFRAMEWORK_ARGS=()

echo "Scanning specified directories for frameworks and dSYMs..."

for dir_name in "$@"; do
    dir="$SRC_DIR/$dir_name"
    if [ -d "$dir" ]; then
        FOUND=false
        # Iterate over .framework bundles 1 level deep inside the directory
        for fw in "$dir"/*.framework; do
            if [ -d "$fw" ]; then
                FOUND=true
                # xcodebuild requires absolute paths for reliability
                abs_fw=$(realpath "$fw")
                echo "  Found Framework: $fw"
                XCFRAMEWORK_ARGS+=("-framework" "$abs_fw")
                
                # Check for a corresponding .dSYM file
                fw_name=$(basename "$fw" .framework)
                dsym="$dir/${fw_name}.dSYM"
                echo "  Checking for dSYM: $dsym"
                if [ -d "$dsym" ]; then
                    abs_dsym=$(realpath "$dsym")
                    echo "  Found matching dSYM: $dsym"
                    XCFRAMEWORK_ARGS+=("-debug-symbols" "$abs_dsym")
                else
                    # Alternative check based on framework name in the same dir
                    possible_dsym="$dir/${fw_name}.framework.dSYM"
                    if [ -d "$possible_dsym" ]; then
                        abs_dsym=$(realpath "$possible_dsym")
                        echo "  Found matching dSYM: $possible_dsym"
                        XCFRAMEWORK_ARGS+=("-debug-symbols" "$abs_dsym")
                    fi
                fi
            fi
        done
        if ! $FOUND; then
            echo "Error: No framework found in '$dir'." >&2
            exit 1
        fi
    else
        echo "Error: '$dir' is not a valid directory." >&2
        exit 1
    fi
done

# Verify that we actually found frameworks to combine
if [ ${#XCFRAMEWORK_ARGS[@]} -eq 0 ]; then
    echo "Error: No .framework files were found in the provided directories."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
STAGE=$(mktemp -d "$OUTPUT_DIR/.combine.XXXXXX")
cleanup() {
    # Restore the previous package if publishing the new one failed.
    if [ -d "$STAGE/previous.xcframework" ] && [ ! -e "$OUTPUT_PATH" ]; then
        if ! mv "$STAGE/previous.xcframework" "$OUTPUT_PATH"; then
            echo "Could not restore previous package. It remains at $STAGE/previous.xcframework" >&2
            return 1
        fi
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
echo "Creating XCFramework at '$OUTPUT_PATH'..."
xcodebuild -create-xcframework "${XCFRAMEWORK_ARGS[@]}" -output "$STAGE/WebRTC.xcframework"
if [ -e "$OUTPUT_PATH" ]; then
    mv "$OUTPUT_PATH" "$STAGE/previous.xcframework"
fi
mv "$STAGE/WebRTC.xcframework" "$OUTPUT_PATH"

echo "Done! Successfully generated: $OUTPUT_PATH"
