// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DustlessMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DustlessApp",
            path: "Sources/DustlessApp"
        )
    ]
)
