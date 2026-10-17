// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VideoToolkit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VideoToolkit",
            path: "Sources/VideoToolkit"
        ),
    ]
)
