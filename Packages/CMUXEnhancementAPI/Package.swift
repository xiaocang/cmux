// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXEnhancementAPI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXEnhancementAPI",
            targets: ["CMUXEnhancementAPI"]
        ),
    ],
    targets: [
        .target(name: "CMUXEnhancementAPI"),
        .testTarget(
            name: "CMUXEnhancementAPITests",
            dependencies: ["CMUXEnhancementAPI"]
        ),
    ]
)
