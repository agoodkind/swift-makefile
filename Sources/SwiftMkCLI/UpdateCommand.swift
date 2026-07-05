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
import SwiftMkUpdate

// MARK: - UpdateCommand

struct UpdateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "update",
    abstract: "Check, apply, and inspect swift-mk self-updates.",
    subcommands: [UpdateCheck.self, UpdateApply.self, UpdateStatus.self]
  )
}

// MARK: - UpdateCommandOptions

struct UpdateCommandOptions: ParsableArguments {
  @Option(name: .long, help: "GitHub repository in owner/name form.")
  var repo = "agoodkind/swift-makefile"

  @Option(name: .customLong("asset"), help: "Release asset name to install.")
  var assetName = "swift-mk_darwin_arm64.dmg"

  @Option(name: .customLong("target"), help: "Binary path to replace.")
  var targetPath = SwiftMkUpdate.UpdateOptions.defaultTargetPath()

  @Option(name: .customLong("team-id"), help: "Required Developer ID team identifier.")
  var teamID = "H3BMXM4W7H"

  @Option(name: .customLong("current-version"), help: "Current release version tag.")
  var currentVersion = ReleaseVersion.current

  @Option(
    name: .customLong("binary"),
    help: "Binary name inside the dmg; defaults to the target file name.")
  var binary: String?

  func updateOptions(dryRun: Bool = false) -> SwiftMkUpdate.UpdateOptions {
    // Derive the binary name from the target so --target generalizes to any
    // consumer: the dmg candidate lookup and the cache/state namespace follow
    // the target's file name rather than a hardcoded "swift-mk".
    let resolvedBinary = binary ?? URL(fileURLWithPath: targetPath).lastPathComponent
    let config = UpdateConfig(
      repo: repo,
      binary: resolvedBinary,
      teamID: teamID,
      currentVersion: currentVersion,
      assetName: assetName)
    return SwiftMkUpdate.UpdateOptions(
      config: config,
      targetPath: targetPath,
      dryRun: dryRun,
      log: Output.info)
  }
}

// MARK: - UpdateCheck

struct UpdateCheck: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "check")

  @OptionGroup var options: UpdateCommandOptions

  func run() throws {
    do {
      let result = try Updater(options: options.updateOptions()).check()
      Output.log("current version: \(result.currentVersion)")
      Output.log("latest tag:      \(result.latestTag)")
      Output.log("asset:           \(result.assetName)")
      Output.log("update available: \(result.updateAvailable ? "yes" : "no")")
    } catch {
      Output.logError("swift-mk: update check failed: \(error)")
      throw ExitCode(1)
    }
  }
}

// MARK: - UpdateApply

struct UpdateApply: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "apply")

  @OptionGroup var options: UpdateCommandOptions
  @Flag(name: .customLong("dry-run"), help: "Stage and verify without replacing the binary.")
  var dryRun = false

  func run() throws {
    do {
      let result = try Updater(options: options.updateOptions(dryRun: dryRun)).apply()
      if !result.check.updateAvailable {
        Output.log("swift-mk: already current")
        return
      }
      if result.dryRun {
        Output.log("swift-mk: update apply dry run ok")
        return
      }
      if result.applied {
        Output.log("swift-mk: update applied")
      }
    } catch {
      Output.logError("swift-mk: update apply failed: \(error)")
      throw ExitCode(1)
    }
  }
}

// MARK: - UpdateStatus

struct UpdateStatus: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status")

  @OptionGroup var options: UpdateCommandOptions

  func run() throws {
    do {
      let updateOptions = options.updateOptions()
      let state = try loadState(path: updateOptions.statePath)
      Output.log("current version: \(options.currentVersion)")
      if let lastCheck = state.lastCheck {
        Output.log("last check:      \(Self.format(lastCheck))")
      }
      if let lastAppliedTag = state.lastAppliedTag, !lastAppliedTag.isEmpty {
        Output.log("applied tag:     \(lastAppliedTag)")
      }
      if let lastResult = state.lastResult {
        Output.log("last result:     \(lastResult.rawValue)")
      }
      if let lastError = state.lastError, !lastError.isEmpty {
        Output.log("last error:      \(lastError)")
      }
    } catch {
      Output.logError("swift-mk: update status failed: \(error)")
      throw ExitCode(1)
    }
  }

  private static func format(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
