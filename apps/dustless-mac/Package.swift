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
            swiftSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-F",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
