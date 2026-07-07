//
//  VersionCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-02.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftMkCore
import SwiftMkMaintCore

// MARK: - VersionCommand

struct VersionCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "version")

  func run() {
    runVersion(log: Output.log)
  }
}
