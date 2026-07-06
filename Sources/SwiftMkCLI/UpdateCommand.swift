//
//  UpdateCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-02.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftMkCore
import SwiftMkMaintCore

// MARK: - UpdateCommand

struct UpdateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "update",
    abstract: "Check, apply, and inspect swift-mk self-updates.",
    subcommands: [UpdateCheck.self, UpdateApply.self, UpdateStatus.self]
  )
}

// MARK: - UpdateCheck

struct UpdateCheck: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "check")

  @OptionGroup var options: UpdateCommandOptions

  func run() throws {
    try runUpdateCheck(
      options: options,
      log: Output.log,
      logError: Output.logError,
      info: Output.info)
  }
}

// MARK: - UpdateApply

struct UpdateApply: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "apply")

  @OptionGroup var options: UpdateCommandOptions
  @Flag(name: .customLong("dry-run"), help: "Stage and verify without replacing the binary.")
  var dryRun = false

  func run() throws {
    try runUpdateApply(
      options: options,
      dryRun: dryRun,
      log: Output.log,
      logError: Output.logError,
      info: Output.info)
  }
}

// MARK: - UpdateStatus

struct UpdateStatus: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status")

  @OptionGroup var options: UpdateCommandOptions

  func run() throws {
    try runUpdateStatus(
      options: options,
      log: Output.log,
      logError: Output.logError,
      info: Output.info)
  }
}
