// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Slate",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SlateCore",
            path: "Sources/SlateCore"
        ),
        .executableTarget(
            name: "Slate",
            dependencies: ["SlateCore"],
            path: "Sources/Slate"
        ),
        .executableTarget(
            name: "SlateChecks",
            dependencies: ["SlateCore"],
            path: "Sources/SlateChecks"
        ),
    ]
)
