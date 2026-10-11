#!/bin/bash
set -e

BRANCH_HEAD=${1:-""}
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBRTC_DIR="$WORK_DIR/webrtc"
DEPOT_TOOLS_DIR="$WEBRTC_DIR/depot_tools"

echo "=== Step 1: Setting up depot_tools ==="
if [ ! -d "$DEPOT_TOOLS_DIR" ]; then
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
else
    echo "depot_tools are in place."
fi
export PATH="$DEPOT_TOOLS_DIR:$PATH"

mkdir -p "$WEBRTC_DIR"
cd "$WEBRTC_DIR"

# 1. Ensure source tree is in place
if [ ! -d "src" ]; then
    echo "WebRTC source tree not found. Fetching now (this will take a while)..."
    fetch --nohooks webrtc
    cd src
    if [ -n "$BRANCH_HEAD" ]; then
        BRANCH="branch-heads/$BRANCH_HEAD"
        echo "Checking out initial version $BRANCH_HEAD (Branch: $BRANCH)..."
        git fetch origin
        git checkout refs/remotes/"$BRANCH"
    fi
else
    cd src
    echo "WebRTC source directory found."
fi

# 2. Interactive version prompt once source is in place
CURRENT_BRANCH=$(git branch --show-current)
CURRENT_COMMIT=$(git rev-parse --short HEAD)
CURRENT_POSITION=$(git log -n 1 --grep="Cr-Commit-Position" --pretty=format:"%s" | sed 's/.*Cr-Commit-Position: //')
CURRENT_REF=$(git name-rev --name-only HEAD)

echo ""
echo "--------------------------------------------------"
echo "Current WebRTC Branch : ${CURRENT_BRANCH:-DETACHED/HEAD}"
echo "Current Git Commit    : $CURRENT_COMMIT"
echo "Current Git Log line  : $CURRENT_POSITION"
echo "Current Git Reference : $CURRENT_REF"
echo "--------------------------------------------------"
echo ""

echo "Please see https://chromiumdash.appspot.com/branches for branch-heads and milestones"

read -p "To preserve current checkout Press [Enter], or type a new BRANCH_HEADER (e.g., 8078) to switch to: " USER_INPUT

if [ -n "$USER_INPUT" ]; then
    BRANCH_HEAD="$USER_INPUT"
    echo "Switching to branch head $BRANCH_HEAD..."
    BRANCH="branch-heads/$BRANCH_HEAD"

    echo "Switching to branch head $BRANCH_HEAD (Mapping to branch: $BRANCH)..."

    # 1. Fetch all remote branch heads
    git fetch origin "+refs/branch-heads/*:refs/remotes/branch-heads/*"

    # 2. List recent branch heads to find the number you want
    git branch -r | grep "branch-heads/" | tail -n 10

    # 3. Detach HEAD onto the target branch (e.g., branch-heads/7920)
    git checkout "refs/remotes/${BRANCH}"
else
    echo "Keeping current version configuration."
fi

echo "=== Running gclient sync (with iOS support enabled) ==="
cd "$WEBRTC_DIR"
gclient sync -D --with_branch_heads

echo "WebRTC source sync completed successfully!"
