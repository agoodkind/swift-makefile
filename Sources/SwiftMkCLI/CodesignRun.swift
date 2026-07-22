//
//  CodesignRun.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftMkCore

// MARK: - CodesignRun

/// Sign artifacts through the one canonical codesign channel. Resolves the
/// identity the same way the build-time override does and applies the fixed
/// flag set for the artifact kind, then verifies strictly.
struct CodesignRun: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "codesign-run",
    abstract: "Sign artifacts with the resolved identity and canonical flags."
  )

  @Option(name: .long, help: "Artifact kind: binary or dmg.")
  var mode: String = "binary"

  @Option(
    name: .customLong("preserve-metadata"),
    help: "codesign --preserve-metadata value; re-signs nested code in place, skips --identifier."
  )
  var preserveMetadata: String?

  @Option(name: .long, help: "Bundle identifier applied to every path.")
  var identifier: String?

  @Option(
    name: .customLong("identifier-prefix"),
    help: "Derive each path's identifier as <prefix>.<basename>; --identifier wins when both set."
  )
  var identifierPrefix: String?

  @Option(
    name: .customLong("bundles-in"),
    help: "Directory whose top-level *.bundle resource bundles are signed alongside the paths."
  )
  var bundlesIn: String?

  @Option(name: .long, help: "Local xcconfig consulted for blank signing values.")
  var localXcconfig: String = "Config/local.xcconfig"

  @Option(name: .long, help: "Keychain path passed to codesign --keychain.")
  var keychain: String?

  @Argument(help: "Paths to sign.")
  var paths: [String] = []

  func run() throws {
    guard let parsedMode = Codesign.Mode(rawValue: mode) else {
      throw ValidationError("codesign-run: unknown mode '\(mode)'")
    }
    Output.info("codesign-run: signing \(paths.count) path(s) in \(mode) mode")
    guard
      Codesign.run(
        paths: paths,
        mode: parsedMode,
        identifier: identifier,
        identifierPrefix: identifierPrefix,
        bundlesDirectory: bundlesIn,
        keychain: keychain,
        preserveMetadata: preserveMetadata,
        localXcconfigPaths: [localXcconfig]
      )
    else {
      throw ExitCode(1)
    }
  }
}
