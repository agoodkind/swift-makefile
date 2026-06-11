//
//  NotarizeCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftMkCore

// MARK: - NotarizeCommand

/// Notarize and staple artifacts through the one canonical channel. CI
/// authenticates with the App Store Connect key trio; a local run uses a
/// notarytool keychain profile. Stapling follows each artifact's shape.
struct NotarizeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "notarize",
    abstract: "Notarize artifacts and staple tickets where the shape allows."
  )

  @Argument(help: "Paths of .dmg, .pkg, or .zip artifacts to notarize.")
  var paths: [String]

  func run() throws {
    Output.info("notarize: processing \(paths.count) artifact(s)")
    guard Notarize.run(paths: paths) else {
      throw ExitCode(1)
    }
  }
}
