# Local WebRTC Library Workspace

This workspace builds Google WebRTC locally and packages it for integration into Swift and Xcode projects via Swift Package Manager (SPM).

## Prerequisites
- macOS with Xcode installed (Command Line Tools configured: `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`)
- Python 3 and Git installed
- ~30 GB of free disk space (due to Chromium/WebRTC dependencies)

---

## Instructions

### Interactive build (recommended)

```bash
./scripts/create_lib.sh
```

The guided CLI shows the current WebRTC commit, reference, and date, then lets you
keep that checkout, enter a branch-head (`8078` or `8078_12`), or select a milestone
(`M156`). Its milestone browser uses Google's
[Version History API](https://developer.chrome.com/docs/web-platform/versionhistory/reference),
with a local cache for network outages. Listed dates are rollout dates for the
displayed Chrome Stable versions, not WebRTC branch-cut dates. Milestones M80 and
newer map to numeric Chromium branch numbers; Git verifies the WebRTC branch when
fetching. Unreleased milestones can be selected by entering their branch-head.

Choose any combination of `ios-arm64`, `simulator-arm64`, `simulator-x86_64`,
`macos-arm64`, and `macos-x86_64`, then Release or Debug. Both macOS architectures
are merged into one universal framework. The CLI shows a summary and asks before
starting, then prepares sources, builds the selected platforms, and packages
`artifacts/WebRTC.xcframework`. Existing checkouts can skip dependency sync;
version switching requires a clean WebRTC working tree.

Enter `q` to cancel any prompt. Colors are automatic in terminals; set `NO_COLOR=1`
to disable them. Preview selections and commands without syncing or compiling:

```bash
./scripts/create_lib.sh --dry-run
```

The lower-level scripts remain usable independently as described below.

To run the workflow checks with mocked build tools:

```bash
python3 -m unittest discover -s scripts/tests -v
```

### Step 1: Download WebRTC Source Code
To fetch the latest master branch:
```bash
./scripts/prepare_webrtc_src.sh
```

Use the interactive builder to browse milestones and release dates. To select a
branch-head directly without a second prompt:

```bash
./scripts/prepare_webrtc_src.sh --non-interactive 8078
```

### Step 2: Build *iOS* Framework
Compiles slices for iOS physical devices (arm64) and iOS simulators (x86_64, arm64 Apple Silicon) into an XCFramework with dSYMs:
```bash
./scripts/build_ios.sh
```
This will put them into 'wbrtc/src/out/ios' subfolders

Pass specific architectures to build a subset, for example:
`./scripts/build_ios.sh device:arm64 simulator:arm64`.

### Step 3: Build *macOS* Framework
With no arguments, compiles the original x86_64 Debug macOS framework with dSYMs:
```bash
./scripts/build_macos.sh
```
This will put them into 'wbrtc/src/out/macos' subfolder

For a universal Release build, run:

```bash
BUILD_CONFIG=release ./scripts/build_macos.sh arm64 x64
```

Explicit architectures use `out/macos-arm64` and `out/macos-x64`; selecting both
also creates `out/macos-universal`, which is the directory to pass to the combine
script. Both build scripts accept `BUILD_CONFIG=release` or `BUILD_CONFIG=debug`.

### Step 4: Combine *.xcframework*
Combines .framework files into multiplatform *WebRTC.xcframework*:
```bash
./scripts/combine_xcframework.sh ios/device ios/simulator macos
```
Where `ios/device ios/simulator macos` are folder names relative to `src/out` directory where artifacts from
previous steps are placed.

---

## Build provenance

Each newly built framework contains `WebRTC.build-info.json` (in `Resources` for
versioned macOS bundles). It records the full WebRTC and builder Git commits,
local-change fingerprints, WebRTC reference and commit position, configuration,
Xcode version, platform, and architectures. References are descriptive; the full
commit SHA identifies the source. A milestone is not inferred from a branch name.

The combined manifest is saved both inside `artifacts/WebRTC.xcframework` and as
`artifacts/WebRTC.build-info.json`. Inspect it with:

```bash
python3 -m json.tool artifacts/WebRTC.build-info.json
```

## Integration into Other Projects

1. Open host application project in **Xcode**.

2. Go to *File > Add Packages...*

3. Click *Add Local...* and select the **LocalWebRTCLibrary** directory.

4. Link WebRTC into target's Frameworks/Libraries build phase.

---

## Notes

1. In every subfolder that SPM needs to ignore, the dummy `Package.swift` file is put. That's done intentionally to prevent Xcode from parsing 30+ GiB source files and artifacts from `webrtc` and `artifacts` folders.
