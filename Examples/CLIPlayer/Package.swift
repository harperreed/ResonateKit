// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CLIPlayer",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "CLIPlayer",
            dependencies: [
                .product(name: "ResonateKit", package: "ResonateKit")
            ]
        ),
        .executableTarget(
            name: "AudioTest",
            dependencies: [
                .product(name: "ResonateKit", package: "ResonateKit")
            ]
        ),
        .executableTarget(
            name: "SimpleTest",
            dependencies: [
                .product(name: "ResonateKit", package: "ResonateKit")
            ]
        )
    ]
)
