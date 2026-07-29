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
        .executable(
            name: "ipapatch-lookin",
            targets: ["IPAPatchLookinCLI"]
        ),
    ],
    targets: [
        .target(
            name: "IPAPatchLookinCore"
        ),
        .executableTarget(
            name: "IPAPatchLookinCLI",
            dependencies: ["IPAPatchLookinCore"]
        ),
        .testTarget(
            name: "IPAPatchLookinCoreTests",
            dependencies: ["IPAPatchLookinCore"]
        ),
    ]
)
