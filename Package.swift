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
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0")
    ],
    targets: [
        .target(
            name: "ResonateKit",
            dependencies: [
                .product(name: "Starscream", package: "Starscream")
            ]
        ),
        .testTarget(
            name: "ResonateKitTests",
            dependencies: ["ResonateKit"]
        )
    ]
)
