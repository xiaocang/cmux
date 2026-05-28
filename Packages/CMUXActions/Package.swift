// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXActions",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXActions",
            targets: ["CMUXActions"]
        ),
    ],
    targets: [
        .target(name: "CMUXActions"),
        .testTarget(
            name: "CMUXActionsTests",
            dependencies: ["CMUXActions"]
        ),
    ]
)
