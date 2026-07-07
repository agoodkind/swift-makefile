//
//  UpdateCommandOptions.swift
//  SwiftMkMaintCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import Foundation
import SwiftMkUpdate

// MARK: - MaintenanceLogHandler

public typealias MaintenanceLogHandler = (String) -> Void

// MARK: - UpdateCommandOptions

public struct UpdateCommandOptions: ParsableArguments {
  @Option(name: .long, help: "GitHub repository in owner/name form.")
  public var repo = "agoodkind/swift-makefile"

  @Option(name: .customLong("asset"), help: "Release asset name to install.")
  public var assetName = "swift-mk_darwin_arm64.dmg"

  @Option(name: .customLong("target"), help: "Binary path to replace.")
  public var targetPath = SwiftMkUpdate.UpdateOptions.defaultTargetPath()

  @Option(name: .customLong("team-id"), help: "Required Developer ID team identifier.")
  public var teamID = "H3BMXM4W7H"

  @Option(name: .customLong("current-version"), help: "Current release version tag.")
  public var currentVersion = ReleaseVersion.current

  @Option(
    name: .customLong("binary"),
    help: "Binary name inside the dmg; defaults to the target file name.")
  public var binary: String?

  public init() {
    // ArgumentParser populates the option wrapper storage during parsing.
  }

  public func updateOptions(
    log: @escaping MaintenanceLogHandler,
    dryRun: Bool = false
  ) -> SwiftMkUpdate.UpdateOptions {
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
      log: log)
  }
}

// MARK: - Shared runners

public func runVersion(log: MaintenanceLogHandler) {
  log("version: \(ReleaseVersion.current)")
}

public func runUpdateCheck(
  options: UpdateCommandOptions,
  log: MaintenanceLogHandler,
  logError: MaintenanceLogHandler,
  info: @escaping MaintenanceLogHandler
) throws {
  do {
    let result = try Updater(options: options.updateOptions(log: info)).check()
    log("current version: \(result.currentVersion)")
    log("latest tag:      \(result.latestTag)")
    log("asset:           \(result.assetName)")
    log("update available: \(result.updateAvailable ? "yes" : "no")")
  } catch {
    logError("swift-mk: update check failed: \(error)")
    throw ExitCode(1)
  }
}

public func runUpdateApply(
  options: UpdateCommandOptions,
  dryRun: Bool,
  log: MaintenanceLogHandler,
  logError: MaintenanceLogHandler,
  info: @escaping MaintenanceLogHandler
) throws {
  do {
    let result = try Updater(options: options.updateOptions(log: info, dryRun: dryRun)).apply()
    if !result.check.updateAvailable {
      log("swift-mk: already current")
      return
    }
    if result.dryRun {
      log("swift-mk: update apply dry run ok")
      return
    }
    if result.applied {
      log("swift-mk: update applied")
    }
  } catch {
    logError("swift-mk: update apply failed: \(error)")
    throw ExitCode(1)
  }
}

public func runUpdateStatus(
  options: UpdateCommandOptions,
  log: MaintenanceLogHandler,
  logError: MaintenanceLogHandler,
  info: @escaping MaintenanceLogHandler
) throws {
  do {
    let updateOptions = options.updateOptions(log: info)
    let state = try loadState(path: updateOptions.statePath)
    log("current version: \(options.currentVersion)")
    if let lastCheck = state.lastCheck {
      log("last check:      \(formatUpdateDate(lastCheck))")
    }
    if let lastAppliedTag = state.lastAppliedTag, !lastAppliedTag.isEmpty {
      log("applied tag:     \(lastAppliedTag)")
    }
    if let lastResult = state.lastResult {
      log("last result:     \(lastResult.rawValue)")
    }
    if let lastError = state.lastError, !lastError.isEmpty {
      log("last error:      \(lastError)")
    }
  } catch {
    logError("swift-mk: update status failed: \(error)")
    throw ExitCode(1)
  }
}

@discardableResult
public func runCachePrune(
  path: String,
  maxBytes: UInt64,
  diagnostics: CachePruneDiagnostics,
  log: MaintenanceLogHandler,
  logError: MaintenanceLogHandler
) throws -> CachePruneResult {
  do {
    let result = try CachePruner(diagnostics: diagnostics).prune(path: path, maxBytes: maxBytes)
    let entryNoun = result.evictedEntries.count == 1 ? "entry" : "entries"
    log(
      "cache prune: evicted \(result.evictedEntries.count) \(entryNoun), "
        + "\(result.evictedBytes) bytes; remaining \(result.remainingBytes) bytes")
    return result
  } catch let error as CachePruneError {
    // CachePruneError.description already carries the "cache prune:" prefix, so
    // log it directly to avoid a doubled prefix; only unexpected errors get one.
    logError(error.description)
    throw ExitCode(1)
  } catch {
    logError("cache prune: \(error)")
    throw ExitCode(1)
  }
}

private func formatUpdateDate(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}
