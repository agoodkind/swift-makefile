//
//  ReleasePackageCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftMkCore

// MARK: - ReleasePackageCommand

struct ReleasePackageCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "release-package",
    abstract: "Build swift-mk-maint and the swift-mk engine and write a dmg file for each."
  )

  @Option(
    name: .long,
    help: "Set the release tag that both binaries print with their version command.")
  var tag: String

  @Option(name: .customLong("dist-dir"), help: "Write both dmg files to this folder.")
  var distDir = "dist"

  @Option(
    name: .customLong("signing-engine"),
    help: "Full swift-mk engine path used for signing-identity and codesign-run.")
  var signingEnginePath: String?

  func run() throws {
    do {
      try ReleasePackage.run(
        tag: tag,
        distDir: distDir,
        signingEnginePath: signingEnginePath)
    } catch let error as ReleasePackageError {
      Output.error("release-build: \(error.description)")
      throw ExitCode(1)
    } catch {
      // Foundation errors (missing file, permissions) reach here; localizedDescription
      // reads cleanly, while the ReleasePackageError case above keeps its own message.
      Output.error("release-build: \(error.localizedDescription)")
      throw ExitCode(1)
    }
  }
}
