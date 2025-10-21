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
            targets: ["ResonateKit"]),
    ],
    targets: [
        .target(
            name: "ResonateKit",
            dependencies: []),
        .testTarget(
            name: "ResonateKitTests",
            dependencies: ["ResonateKit"]),
    ]
)
