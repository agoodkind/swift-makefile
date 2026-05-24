// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-makefile",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "swift-mk-render", targets: ["SwiftMkRenderCLI"])
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
    ]
)
