// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GitXCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "GitXCore", targets: ["GitXCore"]),
    ],
    targets: [
        .target(name: "GitXCore"),
        .testTarget(name: "GitXCoreTests", dependencies: ["GitXCore"]),
    ]
)
