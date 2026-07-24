//
//  VerifySigning.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-24.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import Foundation
import SwiftMkCore

// MARK: - VerifySigning

/// Verify the build-time signature matches what swift-mk resolves. `settings`
/// reads `xcodebuild -showBuildSettings` before a build; `artifacts` reads
/// `codesign` on an explicit list of bundles after; `products` discovers the
/// runnable `.app` bundles under a product root and strictly verifies each.
struct VerifySigning: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify-signing",
    abstract: "Verify the build-time signature matches what swift-mk resolves.",
    subcommands: [
      VerifySigningArtifacts.self, VerifySigningProducts.self, VerifySigningSettings.self,
    ]
  )
}

// MARK: - VerifySigningArtifacts

struct VerifySigningArtifacts: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "artifacts")

  @Option(
    name: .customLong("xcconfig"),
    parsing: .upToNextOption,
    help: "Local xcconfig paths to read signing values from when unset in the environment."
  )
  var xcconfigPaths: [String] = []

  @Argument(help: "Built artifacts (.app bundles or binaries) to verify.")
  var paths: [String]

  func run() throws {
    let passed = SigningVerification.verifyArtifacts(
      paths: paths, localXcconfigPaths: xcconfigPaths)
    if !passed {
      throw ExitCode(1)
    }
  }
}

// MARK: - VerifySigningProducts

struct VerifySigningProducts: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "products",
    abstract: "Discover and strictly verify the runnable .app bundles under a product root."
  )

  @Option(
    name: .customLong("root"),
    parsing: .upToNextOption,
    help: "Product root directories to discover runnable .app bundles under."
  )
  var roots: [String]

  @Option(
    name: .customLong("xcconfig"),
    parsing: .upToNextOption,
    help: "Local xcconfig paths to read signing values from when unset in the environment."
  )
  var xcconfigPaths: [String] = []

  func run() throws {
    let passed = SigningVerification.verifyProducts(
      roots: roots, localXcconfigPaths: xcconfigPaths)
    if !passed {
      throw ExitCode(1)
    }
  }
}

// MARK: - VerifySigningSettings

struct VerifySigningSettings: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "settings")

  @Option(name: .customLong("workspace")) var workspace: String
  @Option(name: .customLong("scheme")) var scheme: String
  @Option(name: .customLong("configuration")) var configuration: String?

  @Option(
    name: .customLong("xcconfig"),
    parsing: .upToNextOption,
    help: "Local xcconfig paths to read signing values from when unset in the environment."
  )
  var xcconfigPaths: [String] = []

  func run() throws {
    let passed = SigningVerification.verifySettings(
      workspace: workspace,
      scheme: scheme,
      configuration: configuration,
      localXcconfigPaths: xcconfigPaths)
    if !passed {
      throw ExitCode(1)
    }
  }
}
