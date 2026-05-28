// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXContracts",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXContracts",
            targets: ["CMUXContracts"]
        ),
    ],
    targets: [
        .target(name: "CMUXContracts"),
        .testTarget(
            name: "CMUXContractsTests",
            dependencies: ["CMUXContracts"]
        ),
    ]
)
