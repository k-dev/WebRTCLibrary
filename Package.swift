// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "WebRTCLibrary",
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
            path: "artifacts/WebRTC.xcframework"
        )
    ]
)
