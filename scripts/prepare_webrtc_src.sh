#!/bin/bash
set -e

BRANCH_HEAD=""
INTERACTIVE=true
while [ "$#" -gt 0 ]; do
    case "$1" in
        --non-interactive) INTERACTIVE=false ;;
        --help|-h) echo "Usage: $0 [--non-interactive] [branch-head (e.g. 8078 or 8078_12)]"; exit 0 ;;
        *)
            if [ -n "$BRANCH_HEAD" ] || [[ ! "$1" =~ ^[0-9]+(_[0-9]+)?$ ]]; then
                echo "Invalid branch-head: $1" >&2; exit 1
            fi
            BRANCH_HEAD="$1"
            INTERACTIVE=false
            ;;
    esac
    shift
done
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
else
    cd src
    echo "WebRTC source directory found."
fi

if ! git rev-parse --verify HEAD >/dev/null 2>&1 || [ -n "$(git rev-parse --show-prefix)" ]; then
    echo "Error: webrtc/src is not a standalone Git checkout." >&2
    exit 1
fi

# 2. Interactive version prompt once source is in place
CURRENT_BRANCH=$(git branch --show-current)
CURRENT_COMMIT=$(git rev-parse --short HEAD)
CURRENT_POSITION=$(git log -1 --format=%B | sed -n 's/^Cr-Commit-Position: //p')
CURRENT_REF=$(git name-rev --name-only HEAD)

echo ""
echo "--------------------------------------------------"
echo "Current WebRTC Branch : ${CURRENT_BRANCH:-DETACHED/HEAD}"
echo "Current Git Commit    : $CURRENT_COMMIT"
echo "Current Git Log line  : $CURRENT_POSITION"
echo "Current Git Reference : $CURRENT_REF"
echo "--------------------------------------------------"
echo ""

if $INTERACTIVE; then
    echo "For milestone selection, use ./scripts/create_lib.sh."
    read -r -p "Press [Enter] to keep this checkout, or enter a branch-head (e.g. 8078): " BRANCH_HEAD
fi

if [ -n "$BRANCH_HEAD" ]; then
    [[ "$BRANCH_HEAD" =~ ^[0-9]+(_[0-9]+)?$ ]] || { echo "Invalid branch-head." >&2; exit 1; }
    if [ -n "$(git status --porcelain)" ]; then
        echo "Cannot switch versions: WebRTC has local changes. Commit or stash them first." >&2
        exit 1
    fi
    echo "Switching to branch-head $BRANCH_HEAD..."
    git fetch origin "+refs/branch-heads/$BRANCH_HEAD:refs/remotes/branch-heads/$BRANCH_HEAD"
    git checkout --detach "refs/remotes/branch-heads/$BRANCH_HEAD"
else
    echo "Keeping current version configuration."
fi

echo "=== Running gclient sync (with iOS support enabled) ==="
cd "$WEBRTC_DIR"
# A fresh `fetch webrtc` checkout does not necessarily include iOS dependencies.
# Preserve existing configuration and add the required target OS values if needed.
python3 - <<'PY'
import ast
from pathlib import Path

config = Path('.gclient')
text = config.read_text()
targets = []
for node in ast.parse(text).body:
    if isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == 'target_os'
        for target in node.targets
    ):
        targets = list(ast.literal_eval(node.value))
required = list(dict.fromkeys(targets + ['ios', 'mac']))
if required != targets:
    with config.open('a') as output:
        output.write('\n# Required by the local Apple framework builders.\n')
        output.write(f'target_os = {required!r}\n')
PY
gclient sync #-D --with_branch_heads --force

echo "WebRTC source sync completed successfully!"
