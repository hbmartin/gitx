// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ForgeKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ForgeKit", targets: ["ForgeKit"]),
        .library(name: "GitHubForgeAdapter", targets: ["GitHubForgeAdapter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apollographql/apollo-ios.git", exact: "2.3.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
    ],
    targets: [
        .target(
            name: "ForgeKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "GitHubForgeAdapter",
            dependencies: [
                "ForgeKit",
                .product(name: "Apollo", package: "apollo-ios"),
                .product(name: "ApolloAPI", package: "apollo-ios"),
            ]
        ),
        .testTarget(
            name: "ForgeKitTests",
            dependencies: [
                "ForgeKit",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(name: "GitHubForgeAdapterTests", dependencies: ["GitHubForgeAdapter"]),
    ]
)
