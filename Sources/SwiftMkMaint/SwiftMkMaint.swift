//
//  SwiftMkMaint.swift
//  SwiftMkMaint
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import SwiftMkMaintCore

// MARK: - SwiftMkMaint

@main
struct SwiftMkMaint: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "swift-mk-maint",
    abstract: "swift-makefile maintenance tooling.",
    version: ReleaseVersion.current,
    subcommands: [
      MaintVersionCommand.self,
      MaintUpdateCommand.self,
      MaintCacheCommand.self,
    ]
  )
}

// MARK: - MaintVersionCommand

struct MaintVersionCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "version")

  func run() {
    runVersion(log: MaintenanceOutput.log)
  }
}

// MARK: - MaintUpdateCommand

struct MaintUpdateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "update",
    abstract: "Check, apply, and inspect swift-mk self-updates.",
    subcommands: [MaintUpdateCheck.self, MaintUpdateApply.self, MaintUpdateStatus.self]
  )
}

// MARK: - MaintUpdateCheck

struct MaintUpdateCheck: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "check")

  @OptionGroup var options: UpdateCommandOptions

  func run() throws {
    try runUpdateCheck(
      options: options,
      log: MaintenanceOutput.log,
      logError: MaintenanceOutput.logError,
      info: MaintenanceOutput.info)
  }
}

// MARK: - MaintUpdateApply

struct MaintUpdateApply: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "apply")

  @OptionGroup var options: UpdateCommandOptions
  @Flag(name: .customLong("dry-run"), help: "Stage and verify without replacing the binary.")
  var dryRun = false

  func run() throws {
    try runUpdateApply(
      options: options,
      dryRun: dryRun,
      log: MaintenanceOutput.log,
      logError: MaintenanceOutput.logError,
      info: MaintenanceOutput.info)
  }
}

// MARK: - MaintUpdateStatus

struct MaintUpdateStatus: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status")

  @OptionGroup var options: UpdateCommandOptions

  func run() throws {
    try runUpdateStatus(
      options: options,
      log: MaintenanceOutput.log,
      logError: MaintenanceOutput.logError,
      info: MaintenanceOutput.info)
  }
}

// MARK: - MaintCacheCommand

struct MaintCacheCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cache",
    abstract: "Manage local build caches.",
    subcommands: [MaintCachePruneCommand.self]
  )
}

// MARK: - MaintCachePruneCommand

struct MaintCachePruneCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prune",
    abstract: "Evict least-recently-used top-level entries until a cache is at a byte cap."
  )

  @Option(name: .long, help: "Directory whose top-level entries should be pruned.")
  var path: String

  @Option(name: .customLong("max-bytes"), help: "Maximum total bytes to keep.")
  var maxBytes: UInt64

  func run() throws {
    let diagnostics = CachePruneDiagnostics(
      info: MaintenanceOutput.info,
      warning: MaintenanceOutput.warning,
      error: MaintenanceOutput.error)
    try runCachePrune(
      path: path,
      maxBytes: maxBytes,
      diagnostics: diagnostics,
      log: MaintenanceOutput.log,
      logError: MaintenanceOutput.logError)
  }
}
