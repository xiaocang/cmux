// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXContextAgent",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXContextAgent",
            targets: ["CMUXContextAgent"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXContracts"),
    ],
    targets: [
        .target(
            name: "CMUXContextAgent",
            dependencies: ["CMUXContracts"]
        ),
        .testTarget(
            name: "CMUXContextAgentTests",
            dependencies: [
                "CMUXContextAgent",
                "CMUXContracts",
            ]
        ),
    ]
)
