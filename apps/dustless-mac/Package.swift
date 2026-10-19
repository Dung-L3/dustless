// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DustlessMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DustlessKit",
            path: "Sources/DustlessKit"
        ),
        .executableTarget(
            name: "DustlessApp",
            dependencies: ["DustlessKit"],
            path: "Sources/DustlessApp"
        ),
        .testTarget(
            name: "DustlessAppTests",
            dependencies: ["DustlessKit"],
            path: "Tests/DustlessAppTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
