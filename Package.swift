// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwipeFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwipeFlowCore", targets: ["SwipeFlowCore"]),
        .library(name: "SwipeFlowConnectors", targets: ["SwipeFlowConnectors"]),
        .executable(name: "SwipeFlowChecks", targets: ["SwipeFlowChecks"])
    ],
    targets: [
        .target(name: "SwipeFlowCore"),
        .target(
            name: "SwipeFlowConnectors",
            dependencies: ["SwipeFlowCore"]
        ),
        .executableTarget(
            name: "SwipeFlowChecks",
            dependencies: ["SwipeFlowCore", "SwipeFlowConnectors"]
        ),
        .testTarget(
            name: "SwipeFlowCoreTests",
            dependencies: ["SwipeFlowCore"]
        ),
        .testTarget(
            name: "SwipeFlowConnectorsTests",
            dependencies: ["SwipeFlowCore", "SwipeFlowConnectors"]
        )
    ]
)
