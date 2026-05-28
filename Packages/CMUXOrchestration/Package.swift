// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXOrchestration",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXOrchestration",
            targets: ["CMUXOrchestration"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXContracts"),
    ],
    targets: [
        .target(
            name: "CMUXOrchestration",
            dependencies: ["CMUXContracts"]
        ),
        .testTarget(
            name: "CMUXOrchestrationTests",
            dependencies: [
                "CMUXContracts",
                "CMUXOrchestration",
            ]
        ),
    ]
)
