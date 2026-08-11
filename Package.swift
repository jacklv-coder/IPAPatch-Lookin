// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "IPAPatchLookinCLI",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "IPAPatchLookinCore",
            targets: ["IPAPatchLookinCore"]
        ),
        .library(
            name: "IPAPatchLookinProject",
            targets: ["IPAPatchLookinProject"]
        ),
        .executable(
            name: "ipapatch-lookin",
            targets: ["IPAPatchLookinCLI"]
        ),
    ],
    targets: [
        .target(
            name: "IPAPatchLookinCore"
        ),
        .target(
            name: "IPAPatchLookinProject",
            dependencies: ["IPAPatchLookinCore"]
        ),
        .executableTarget(
            name: "IPAPatchLookinCLI",
            dependencies: [
                "IPAPatchLookinCore",
                "IPAPatchLookinProject",
            ]
        ),
        .testTarget(
            name: "IPAPatchLookinCoreTests",
            dependencies: ["IPAPatchLookinCore"]
        ),
        .testTarget(
            name: "IPAPatchLookinProjectTests",
            dependencies: [
                "IPAPatchLookinCore",
                "IPAPatchLookinProject",
            ]
        ),
    ]
)
