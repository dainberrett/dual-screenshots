// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DualScreenshots",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DualScreenshots",
            path: "Sources/DualScreenshots"
        )
    ]
)
