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
    .executable(name: "swift-mk-maint", targets: ["SwiftMkMaint"]),
    .library(name: "SwiftMkCore", targets: ["SwiftMkCore"]),
    .library(name: "SwiftMkRenderCore", targets: ["SwiftMkRenderCore"]),
    .library(name: "SwiftMkUpdate", targets: ["SwiftMkUpdate"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(
      url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", from: "2.4.1"),
    .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", from: "2.4.1"),
    .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.5"),
    // swift-index-store and XcodeProj are the libraries periphery uses. The
    // dead-code gate reuses them to verify the index covers every target
    // source before scanning. swift-index-store uses unsafeFlags to link
    // libIndexStore, so it must be pinned by revision, the same way periphery
    // pins it, not by a version range.
    .package(
      url: "https://github.com/ileitch/swift-index-store",
      revision: "ed1f232d33b8e03956af0f4206fbd30171a43138"),
    .package(url: "https://github.com/tuist/XcodeProj.git", from: "9.13.0"),
    .package(url: "https://github.com/kylef/PathKit.git", from: "1.0.0"),
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
      name: "SwiftMkUpdate"
    ),
    .target(
      name: "SwiftMkMaintCore",
      dependencies: [
        "SwiftMkUpdate",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .target(
      name: "SwiftMkCore",
      dependencies: [
        "SwiftMkRenderCore",
        .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
        .product(name: "OpenTelemetryProtocolExporter", package: "opentelemetry-swift"),
        .product(name: "GRPC", package: "grpc-swift"),
        .product(name: "IndexStore", package: "swift-index-store"),
        .product(name: "XcodeProj", package: "XcodeProj"),
        .product(name: "PathKit", package: "PathKit"),
      ],
      // The gate configs ship as engine-owned resources so CI, make, and the
      // in-process API all materialize byte-identical configs into `.make/`,
      // and the no-make path works on a fresh checkout that has never fetched.
      resources: [
        .copy("Resources/swiftlint.yml"),
        .copy("Resources/swift-format.json"),
        .copy("Resources/periphery.yml"),
        .copy("Resources/osv-scanner.toml"),
        .copy("Resources/mise.toml"),
      ]
    ),
    .executableTarget(
      name: "SwiftMkCLI",
      dependencies: [
        "SwiftMkCore",
        "SwiftMkMaintCore",
        "SwiftMkUpdate",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "SwiftMkMaint",
      dependencies: [
        "SwiftMkMaintCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "SwiftMkCoreTests",
      dependencies: ["SwiftMkCore"],
      exclude: ["Fixtures"]
    ),
    .testTarget(
      name: "SwiftMkUpdateTests",
      dependencies: ["SwiftMkUpdate"]
    ),
    .testTarget(
      name: "SwiftMkMaintCoreTests",
      dependencies: [
        "SwiftMkMaintCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
  ]
)
