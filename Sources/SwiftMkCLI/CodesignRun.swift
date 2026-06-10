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

  @Option(name: .long, help: "Artifact kind: binary, sparkle, or dmg.")
  var mode: String = "binary"

  @Option(name: .long, help: "Bundle identifier for bare binaries.")
  var identifier: String?

  @Option(name: .long, help: "Local xcconfig consulted for blank signing values.")
  var localXcconfig: String = "Config/local.xcconfig"

  @Argument(help: "Paths to sign.")
  var paths: [String]

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
        localXcconfigPaths: [localXcconfig]
      )
    else {
      throw ExitCode(1)
    }
  }
}
