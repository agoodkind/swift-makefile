// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-makefile",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "swift-mk-render", targets: ["SwiftMkRenderCLI"]),
        .executable(name: "swift-mk", targets: ["SwiftMkCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "SwiftMkRenderCore"
        ),
        .executableTarget(
            name: "SwiftMkRenderCLI",
            dependencies: ["SwiftMkRenderCore"]
        ),
        .testTarget(
            name: "SwiftMkRenderCoreTests",
            dependencies: ["SwiftMkRenderCore"]
        ),
        .target(
            name: "SwiftMkCore",
            dependencies: ["SwiftMkRenderCore"]
        ),
        .executableTarget(
            name: "SwiftMkCLI",
            dependencies: [
                "SwiftMkCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SwiftMkCoreTests",
            dependencies: ["SwiftMkCore"]
        ),
    ]
)
