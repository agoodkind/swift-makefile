// swift-tools-version: 6.0
//
//  Package.swift
//  swiftcheck
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import PackageDescription

// MARK: - Package

let package = Package(
  name: "swiftcheck",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "swiftcheck-extra", targets: ["swiftcheck-extra"])
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0")
  ],
  targets: [
    .target(
      name: "SwiftCheckCore",
      dependencies: [
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ]
    ),
    .executableTarget(
      name: "swiftcheck-extra",
      dependencies: [
        "SwiftCheckCore"
      ]
    ),
    .testTarget(
      name: "SwiftCheckCoreTests",
      dependencies: ["SwiftCheckCore"]
    ),
  ]
)
