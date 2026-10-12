#!/bin/bash
# Interactive entry point; compatible with macOS's system Bash 3.2.
set -euo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$WORK_DIR/scripts"
SRC_DIR="$WORK_DIR/webrtc/src"
DRY_RUN=false
case "${1:-}" in
    --dry-run) DRY_RUN=true ;;
    --help|-h)
        echo "Usage: $0 [--dry-run]"
        echo "Choose a WebRTC version, architectures, and build configuration interactively."
        echo "--dry-run shows the selected commands without syncing, building, or packaging."
        exit 0 ;;
    "") ;;
    *) echo "Unknown option: $1 (use --help)" >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || { echo "Use --help for usage." >&2; exit 1; }
for tool in git python3; do
    command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done

BOLD='' BLUE='' GREEN='' YELLOW='' RESET=''
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; BLUE=$'\033[36m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; RESET=$'\033[0m'
fi
heading() { printf '\n%s%s%s\n' "$BOLD$BLUE" "$1" "$RESET"; }
notice() { printf '%s%s%s\n' "$YELLOW" "$1" "$RESET"; }
prompt() {
    printf '\n%s ' "$1"
    if ! IFS= read -r REPLY; then printf '\nInput closed; cancelled.\n'; exit 0; fi
    case "$REPLY" in q|Q|quit) echo "Cancelled."; exit 0 ;; esac
}
trap 'printf "\nCancelled.\n"; exit 130' INT
trap 'printf "\nBuild stopped at line %s. See the command output above.\n" "$LINENO" >&2' ERR

heading "Create WebRTC library"
echo "Enter menu numbers to choose. Enter q at any prompt to cancel."
HAVE_SOURCE=false
DIRTY=false
if git -C "$SRC_DIR" rev-parse --verify HEAD >/dev/null 2>&1 &&
    [ -z "$(git -C "$SRC_DIR" rev-parse --show-prefix)" ]; then
    HAVE_SOURCE=true
    heading "Current WebRTC checkout"
    git -C "$SRC_DIR" log -1 --format='Commit:    %h%nDate:      %cs%nSubject:   %s'
    printf 'Branch:    %s\n' "$(git -C "$SRC_DIR" symbolic-ref --short -q HEAD || echo 'detached HEAD')"
    printf 'Reference: %s\n' "$(git -C "$SRC_DIR" name-rev --name-only HEAD)"
    git -C "$SRC_DIR" log -1 --format=%B | sed -n 's/^Cr-Commit-Position: /Position:  /p'
    if [ -n "$(git -C "$SRC_DIR" status --porcelain)" ]; then
        DIRTY=true
        notice "This checkout has local changes. Version switching is disabled."
    fi
else
    notice "No WebRTC checkout found. Proceeding will fetch the default upstream checkout."
fi

BRANCH_HEAD=''
VERSION_LABEL='current checkout'
if ! $HAVE_SOURCE; then VERSION_LABEL='default upstream checkout'; fi
while :; do
    heading "WebRTC version"
    printf '  1) Proceed with %s\n' "$VERSION_LABEL"
    echo '  2) Enter a branch-head or milestone (8078, 8078_12, M156)'
    echo '  3) Browse recent Stable milestones with dates'
    prompt 'Version [1]:'
    case "${REPLY:-1}" in
        1) break ;;
        2|3)
            if $DIRTY; then
                notice "Commit or stash WebRTC changes before selecting another version."
                continue
            fi
            if [ "$REPLY" = 3 ]; then
                echo "Loading milestone metadata from Google's Version History API..."
                if ! ROWS=$(python3 "$SCRIPTS/lib/milestones.py" list); then continue; fi
                echo "Milestone  Branch-head  Release date  Chrome Stable version"
                while IFS=$'\t' read -r milestone branch date version; do
                    printf 'M%-9s %-12s %-13s %s\n' "$milestone" "$branch" "$date" "$version"
                done <<< "$ROWS"
                echo "Dates are rollout dates for the listed Chrome version, not WebRTC branch-cut dates."
            fi
            prompt 'Enter milestone (M156) or branch-head (8078); Enter returns to menu:'
            [ -n "$REPLY" ] || continue
            SELECTION="$REPLY"
            if [[ "$SELECTION" =~ ^[Mm][0-9]+$ ]]; then
                if ! BRANCH_HEAD=$(python3 "$SCRIPTS/lib/milestones.py" resolve "$SELECTION"); then continue; fi
                VERSION_LABEL="$SELECTION (branch-head $BRANCH_HEAD)"
            elif [[ "$SELECTION" =~ ^[0-9]+(_[0-9]+)?$ ]]; then
                BRANCH_HEAD="$SELECTION"
                VERSION_LABEL="branch-head $BRANCH_HEAD"
            else
                notice 'Use an M prefix for milestones (M156), or a numeric branch-head (8078).'
                continue
            fi
            echo "Selected $VERSION_LABEL; the branch will be verified by Git when fetched."
            break ;;
        *) notice 'Choose 1, 2, or 3.' ;;
    esac
done

heading "Platforms / architectures"
echo '  1) ios-arm64          — physical iPhone / iPad'
echo '  2) simulator-arm64    — Apple Silicon simulator'
echo '  3) simulator-x86_64   — Intel simulator'
echo '  4) macos-arm64        — Apple Silicon Mac'
echo '  5) macos-x86_64       — Intel Mac'
echo '  a) All five architectures'
DEFAULT_PLATFORMS='1 2 4'
if [ "$(uname -m)" = x86_64 ]; then DEFAULT_PLATFORMS='1 3 5'; fi
while :; do
    prompt "Choose one or more numbers, separated by spaces or commas [$DEFAULT_PLATFORMS]:"
    INPUT="${REPLY:-$DEFAULT_PLATFORMS}"
    case "$INPUT" in a|A|all) INPUT='1 2 3 4 5' ;; esac
    INPUT="${INPUT//,/ }"
    IOS_ARCHS=(); MAC_ARCHS=(); COMBINE_DIRS=(); PLATFORM_NAMES=()
    SEEN=' '; VALID=true
    # Validate before expanding tokens; no globs or shell evaluation of user input.
    if [[ ! "$INPUT" =~ ^[1-5[:space:]]+$ ]]; then
        notice 'Choose numbers 1–5, or a for all.'; continue
    fi
    for number in $INPUT; do
        case "$SEEN" in *" $number "*) continue ;; esac
        SEEN="$SEEN$number "
        case "$number" in
            1) IOS_ARCHS+=(device:arm64); PLATFORM_NAMES+=(ios-arm64) ;;
            2) IOS_ARCHS+=(simulator:arm64); PLATFORM_NAMES+=(simulator-arm64) ;;
            3) IOS_ARCHS+=(simulator:x64); PLATFORM_NAMES+=(simulator-x86_64) ;;
            4) MAC_ARCHS+=(arm64); PLATFORM_NAMES+=(macos-arm64) ;;
            5) MAC_ARCHS+=(x64); PLATFORM_NAMES+=(macos-x86_64) ;;
            *) VALID=false ;;
        esac
    done
    if ! $VALID || [ "${#PLATFORM_NAMES[@]}" -eq 0 ]; then notice 'Select at least one platform.'; continue; fi
    break
done
# Only package the requested environments, even if other old outputs exist.
case "$SEEN" in *' 1 '*) COMBINE_DIRS+=(ios/device) ;; esac
case "$SEEN" in *' 2 '*|*' 3 '*) COMBINE_DIRS+=(ios/simulator) ;; esac
if [ "${#MAC_ARCHS[@]}" -eq 2 ]; then
    COMBINE_DIRS+=(macos-universal)
elif [ "${#MAC_ARCHS[@]}" -eq 1 ]; then
    COMBINE_DIRS+=("macos-${MAC_ARCHS[0]}")
fi

heading "Build configuration"
echo '  1) Release'
echo '  2) Debug'
while :; do
    prompt 'Configuration [1]:'
    case "${REPLY:-1}" in
        1) BUILD_CONFIG=release; break ;;
        2) BUILD_CONFIG=debug; break ;;
        *) notice 'Choose 1 or 2.' ;;
    esac
done
export BUILD_CONFIG

SYNC=true
if $HAVE_SOURCE && [ -z "$BRANCH_HEAD" ]; then
    heading "Source preparation"
    echo '  1) Sync dependencies for the current checkout'
    echo '  2) Use the existing checkout and dependencies without syncing'
    DEFAULT_SYNC=1
    if $DIRTY; then DEFAULT_SYNC=2; notice 'Keeping existing sources is recommended while local changes are present.'; fi
    while :; do
        prompt "Source preparation [$DEFAULT_SYNC]:"
        case "${REPLY:-$DEFAULT_SYNC}" in
            1) break ;;
            2) SYNC=false; break ;;
            *) notice 'Choose 1 or 2.' ;;
        esac
    done
fi

heading "Build summary"
printf 'WebRTC:        %s\n' "$VERSION_LABEL"
printf 'Platforms:     %s\n' "${PLATFORM_NAMES[*]}"
printf 'Configuration: %s\n' "$BUILD_CONFIG"
if $SYNC; then echo 'Preparation:   fetch / sync dependencies'; else echo 'Preparation:   use existing sources'; fi
printf 'Output:        %s/artifacts/WebRTC.xcframework\n' "$WORK_DIR"
if [ -d "$WORK_DIR/artifacts/WebRTC.xcframework" ]; then
    notice 'The existing packaged XCFramework will be replaced after packaging succeeds.'
fi

run() {
    printf '\n%s> ' "$GREEN"
    printf '%q ' "$@"
    printf '%s\n' "$RESET"
    if ! $DRY_RUN; then "$@"; fi
}
if $DRY_RUN; then
    notice 'Dry run: showing commands only.'
else
    prompt 'Start this build? [y/N]:'
    case "$REPLY" in y|Y|yes|YES) ;; *) echo 'Cancelled.'; exit 0 ;; esac
    [ "$(uname -s)" = Darwin ] || { echo 'Building requires macOS and Xcode.' >&2; exit 1; }
    xcodebuild -version >/dev/null
fi
if $SYNC; then
    if [ -n "$BRANCH_HEAD" ]; then
        run "$SCRIPTS/prepare_webrtc_src.sh" --non-interactive "$BRANCH_HEAD"
    else
        run "$SCRIPTS/prepare_webrtc_src.sh" --non-interactive
    fi
fi
if [ "${#IOS_ARCHS[@]}" -gt 0 ]; then run "$SCRIPTS/build_ios.sh" "${IOS_ARCHS[@]}"; fi
if [ "${#MAC_ARCHS[@]}" -gt 0 ]; then run "$SCRIPTS/build_macos.sh" "${MAC_ARCHS[@]}"; fi
run "$SCRIPTS/combine_xcframework.sh" "${COMBINE_DIRS[@]}"
if ! $DRY_RUN; then
    heading 'WebRTC library ready'
    printf '%s/artifacts/WebRTC.xcframework\n' "$WORK_DIR"
fi
