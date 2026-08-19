// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FLibInjections",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "FLibInjections",
            targets: ["FLibInjections"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "FLibInjections",
            dependencies: [],
            path: "Sources/FLibInjections"
        )
    ]
)
