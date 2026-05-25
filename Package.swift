// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Slate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Slate",
            path: "Sources/Slate"
        )
    ]
)
