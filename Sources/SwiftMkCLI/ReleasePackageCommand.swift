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
    commandName: "release-package-maint",
    abstract: "Build and package the lean maintenance swift-mk release binary."
  )

  @Option(name: .long, help: "Release tag to stamp into the shipped binary.")
  var tag: String

  @Option(name: .customLong("dist-dir"), help: "Directory for the generated dmg.")
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
