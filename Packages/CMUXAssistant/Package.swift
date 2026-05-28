// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXAssistant",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXAssistant",
            targets: ["CMUXAssistant"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXActions"),
        .package(path: "../CMUXContracts"),
    ],
    targets: [
        .target(
            name: "CMUXAssistant",
            dependencies: [
                "CMUXActions",
                "CMUXContracts",
            ]
        ),
        .testTarget(
            name: "CMUXAssistantTests",
            dependencies: [
                "CMUXActions",
                "CMUXAssistant",
                "CMUXContracts",
            ]
        ),
    ]
)
