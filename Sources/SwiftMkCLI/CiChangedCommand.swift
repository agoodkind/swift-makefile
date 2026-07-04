//
//  CiChangedCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftMkCore

// MARK: - CiChangedCommand

struct CiChangedCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ci-changed",
    abstract: "Detect whether the current CI diff changes build inputs."
  )

  func run() throws {
    Output.debug("ci-changed")
    let status = CiChanged.run()
    if status != 0 { throw ExitCode(status) }
  }
}
