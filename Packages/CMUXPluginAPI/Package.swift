// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXPluginAPI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXPluginAPI",
            targets: ["CMUXPluginAPI"]
        ),
    ],
    targets: [
        .target(name: "CMUXPluginAPI"),
        .testTarget(
            name: "CMUXPluginAPITests",
            dependencies: ["CMUXPluginAPI"]
        ),
    ]
)
