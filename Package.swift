// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "LocalWebRTCLibrary",
    platforms: [
        .iOS(.v13),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "WebRTC",
            targets: ["WebRTCTarget"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTCTarget",
            url: "https://github.com/k-dev/macWebRTCLibrary/releases/download/0.1.0-m156/WebRTC.xcframework.zip",
            checksum: "24ba47ee90cbde9ee091f0c030b24a18bc521c9d6db5d451ffb729fdef49e284"
        )
    ]
)