// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacNative",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacNative",
            path: "Sources/MacNative",
            resources: [.copy("Resources/Fonts")]
        )
    ]
)
