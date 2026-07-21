// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ApkSignatureVerifierKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ApkSignatureVerifierKit",
            // Xcode 26 can omit binaries for transitive PackageProducts when testing a client.
            // Keep this product dynamic so Xcode links the transitive products correctly.
            type: .dynamic,
            targets: ["ApkSignatureVerifierKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.1"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.0"),
    ],
    targets: [
        .target(
            name: "ApkSignatureVerifierKit",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]
        ),
        .testTarget(
            name: "ApkSignatureVerifierKitTests",
            dependencies: ["ApkSignatureVerifierKit"]
        ),
    ]
)
