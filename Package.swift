// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VideoToolkit",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Lokale Spracherkennung (Core ML) – nur Quellcode, zur Laufzeit keine Netzwerknutzung
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "VideoToolkit",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/VideoToolkit"
        ),
    ]
)
