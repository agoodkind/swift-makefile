// swift-tools-version: 6.0
//
//  Package.swift
//  swift-makefile
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import PackageDescription

// MARK: - Package

let package = Package(
    name: "swift-makefile",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "swift-mk-render", targets: ["SwiftMkRenderCLI"]),
        .executable(name: "swift-mk", targets: ["SwiftMkCLI"]),
        .library(name: "SwiftMkCore", targets: ["SwiftMkCore"]),
        .library(name: "SwiftMkRenderCore", targets: ["SwiftMkRenderCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(
            url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", from: "2.4.1"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", from: "2.4.1"),
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.5"),
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
            dependencies: [
                "SwiftMkRenderCore",
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetryProtocolExporter", package: "opentelemetry-swift"),
                .product(name: "GRPC", package: "grpc-swift"),
            ]
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
