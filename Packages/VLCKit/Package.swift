// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VLCKit",
    products: [
        .library(
            name: "VLCKit",
            targets: ["VLCKit", "VLCKitAssets"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "VLCKit",
            path: "VLCKit.xcframework"
        ),
        .target(
            name: "VLCKitAssets",
            path: "VLCKitAssets",
            resources: [
                .copy("COPYING"),
                .copy("dodeca_and_7channel_3DSL_HRTF.sofa"),
            ]
        ),
    ]
)
