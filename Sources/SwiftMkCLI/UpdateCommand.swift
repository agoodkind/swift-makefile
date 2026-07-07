//
//  UpdateCommand.swift
//  SwiftMkCLI
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-02.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import Foundation
import SwiftMkCore
import SwiftMkMaintCore
import SwiftMkUpdate

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

// MARK: - VerifyReleaseCommand

struct VerifyReleaseCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "verify-release",
    abstract: "Verify a published swift-mk release asset."
  )

  @Option(name: .long, help: "GitHub repository in owner/name form.")
  var repo: String

  @Option(name: .long, help: "Release tag to verify.")
  var tag: String

  @Option(name: .customLong("asset"), help: "Release asset name to verify.")
  var assetName: String

  @Option(
    name: .customLong("team-id"),
    help: "Developer ID team identifier; required only with --require-signature.")
  var teamID = ""

  @Flag(
    name: .customLong("require-signature"),
    inversion: .prefixedNo,
    help: "Require staple and Developer ID team verification before running the candidate.")
  var requireSignature = true

  func run() throws {
    do {
      let environment = ProcessInfo.processInfo.environment
      let authToken = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"]
      // The team id is only compared when a signature is required. Demand it in
      // that mode; otherwise pass it through as-is (possibly empty), since
      // verify-release validates with requireTeamID: false and does not need it.
      if requireSignature, teamID.isEmpty {
        Output.logError("swift-mk: verify-release --require-signature needs --team-id")
        throw ExitCode(1)
      }
      let config = UpdateConfig(
        repo: repo,
        binary: "swift-mk",
        teamID: teamID,
        currentVersion: tag,
        assetName: assetName,
        authToken: authToken)
      let options = UpdateOptions(config: config, log: Output.info)
      let result = try Updater(options: options).verifyRelease(
        tag: tag,
        requireSignature: requireSignature)
      for line in result.validationOutput.split(whereSeparator: \.isNewline) {
        Output.log(String(line))
      }
      Output.log("swift-mk: release \(result.tag) verified")
    } catch let exit as ExitCode {
      // A self-thrown ExitCode (for example the missing --team-id guard) already
      // logged its specific message, so rethrow it without a second, vaguer line.
      throw exit
    } catch {
      Output.logError("swift-mk: verify-release failed: \(error)")
      throw ExitCode(1)
    }
  }
}
