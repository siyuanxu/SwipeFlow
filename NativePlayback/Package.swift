// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwipeFlowNativePlayback",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwipeFlowMPV", targets: ["SwipeFlowMPV"])
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .systemLibrary(
            name: "CMPV",
            pkgConfig: "mpv",
            providers: [
                .brew(["mpv", "pkgconf"])
            ]
        ),
        .target(
            name: "SwipeFlowMPV",
            dependencies: [
                "CMPV",
                .product(name: "SwipeFlowCore", package: "swipeflow")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("OpenGL")
            ]
        ),
        .testTarget(
            name: "SwipeFlowMPVTests",
            dependencies: [
                "SwipeFlowMPV",
                .product(name: "SwipeFlowCore", package: "swipeflow")
            ]
        )
    ]
)
