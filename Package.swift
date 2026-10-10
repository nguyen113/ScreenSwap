// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScreenSwap",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ScreenSwapCore",
            targets: ["ScreenSwapCore"]
        ),
        .library(
            name: "ScreenSwapMac",
            targets: ["ScreenSwapMac"]
        ),
        .executable(
            name: "ScreenSwapApp",
            targets: ["ScreenSwapApp"]
        ),
        .executable(
            name: "ScreenSwapBenchmark",
            targets: ["ScreenSwapBenchmark"]
        )
    ],
    targets: [
        .target(
            name: "ScreenSwapCore"
        ),
        .target(
            name: "ScreenSwapMac",
            dependencies: ["ScreenSwapCore"],
            resources: [.copy("Resources/StatusIcons")]
        ),
        .executableTarget(
            name: "ScreenSwapApp",
            dependencies: ["ScreenSwapMac"]
        ),
        .executableTarget(
            name: "ScreenSwapBenchmark",
            dependencies: ["ScreenSwapMac"]
        ),
        .testTarget(
            name: "ScreenSwapCoreTests",
            dependencies: ["ScreenSwapCore"]
        ),
        .testTarget(
            name: "ScreenSwapMacTests",
            dependencies: ["ScreenSwapMac", "ScreenSwapCore"]
        )
    ]
)
