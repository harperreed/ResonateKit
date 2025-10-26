// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ResonateKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "ResonateKit",
            targets: ["ResonateKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0"),
        .package(url: "https://github.com/alta/swift-opus.git", from: "0.0.2"),
        .package(url: "https://github.com/sbooth/flac-binary-xcframework.git", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "ResonateKit",
            dependencies: [
                .product(name: "Starscream", package: "Starscream"),
                .product(name: "Opus", package: "swift-opus"),
                .product(name: "FLAC", package: "flac-binary-xcframework")
            ]
        ),
        .testTarget(
            name: "ResonateKitTests",
            dependencies: ["ResonateKit"]
        )
    ]
)
