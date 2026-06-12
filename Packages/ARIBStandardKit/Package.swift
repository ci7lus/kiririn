// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ARIBStandardKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ARIBStandardKit",
            targets: ["ARIBStandardKit"]
        )
    ],
    targets: [
        .target(
            name: "ARIBStandardKit"
        ),
        .testTarget(
            name: "ARIBStandardKitTests",
            dependencies: ["ARIBStandardKit"]
        ),
    ]
)
