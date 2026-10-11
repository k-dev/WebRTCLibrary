# Local WebRTC Library Workspace

This workspace builds Google WebRTC locally and packages it for integration into Swift and Xcode projects via Swift Package Manager (SPM).

## Prerequisites
- macOS with Xcode installed (Command Line Tools configured: `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`)
- Python 3 and Git installed
- ~30 GB of free disk space (due to Chromium/WebRTC dependencies)

---

## Instructions

### Step 1: Download WebRTC Source Code
To fetch the latest master branch:
```bash
./scripts/prepare_webrtc_src.sh
```

For the list of all official versions of Google WebRTC visit the links
https://chromiumdash.appspot.com/branches
https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac

### Step 2: Build *iOS* Framework
Compiles slices for iOS physical devices (arm64) and iOS simulators (x86_64, arm64 Apple Silicon) into an XCFramework with dSYMs:
```bash
./scripts/build_ios.sh
```
This will put them into 'wbrtc/src/out/ios' subfolders

### Step 3: Build *macOS* Framework
Compiles universal macOS framework (x86_64 and arm64) with dSYMs:
```bash
./scripts/build_macos.sh
```
This will put them into 'wbrtc/src/out/macos' subfolder

### Step 4: Combine *.xcframework*
Compiles universal macOS framework (x86_64 and arm64) with dSYMs:
```bash
./scripts/combine_xcramework.sh ios/device ios/simulator macos
```
Where `ios/device ios/simulator macos` are folder names relative to `src/out` directory where artifacts from
previous steps are placed.

---

## Integration into Other Projects

1. Open host application project in **Xcode**.

2. Go to *File > Add Packages...*

3. Click *Add Local...* and select the **LocalWebRTCLibrary** directory.

4. Link WebRTC into target's Frameworks/Libraries build phase.

---

## Notes

1. In every subfolder that SPM needs to ignore, the dummy `Package.swift` file is put. That's done intentionally to prevent Xcode from parsing 30+ GiB source files and artifacts from `webrtc` and `artifacts` folders.
