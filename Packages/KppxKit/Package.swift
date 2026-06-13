// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KppxKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "KppxKit",
            targets: ["KppxKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20")
    ],
    targets: [
        .target(
            name: "KppxKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .testTarget(
            name: "KppxKitTests",
            dependencies: ["KppxKit"]
        ),
    ]
)
