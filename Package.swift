// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacNative",
    platforms: [.macOS(.v14)],
    targets: [
        // Vendored decompressors for Steam depot chunks (built from source, no system libraries).
        .target(name: "CLzma", path: "Sources/CLzma", exclude: ["LICENSE"]),
        .target(name: "CZstd", path: "Sources/CZstd", exclude: ["LICENSE", "README"],
                cSettings: [.unsafeFlags(["-w"])]),
        .executableTarget(
            name: "MacNative",
            dependencies: ["CLzma", "CZstd"],
            path: "Sources/MacNative",
            resources: [.copy("Resources/Fonts"), .copy("Resources/Logo")]
        ),
        .testTarget(
            name: "MacNativeTests",
            dependencies: ["MacNative"],
            path: "Tests/MacNativeTests",
            resources: [.copy("vzip_fixture.hex")]
        )
    ]
)
