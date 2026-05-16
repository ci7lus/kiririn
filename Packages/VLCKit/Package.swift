// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VLCKit",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "VLCKit",
            targets: ["VLCKit", "VLCKitLicense"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "VLCKit",
            path: "VLCKit.xcframework"
        ),
        .target(
            name: "VLCKitLicense",
            path: "VLCKitLicense",
            resources: [
                .copy("COPYING")
            ]
        ),
    ]
)
