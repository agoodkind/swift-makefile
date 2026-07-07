//
//  MaintenanceRunnersTests.swift
//  SwiftMkMaintCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import ArgumentParser
import Foundation
import Testing

@testable import SwiftMkMaintCore

// MARK: - MaintenanceRunnersTests

@Suite(.serialized)
enum MaintenanceRunnersTests {
  @Test
  static func versionRunnerWritesReleaseVersion() {
    var messages: [String] = []

    runVersion { message in
      messages.append(message)
    }

    #expect(messages == ["version: dev"])
  }

  @Test
  static func updateOptionsDerivesBinaryFromTargetPath() throws {
    let options = try UpdateCommandOptions.parse([
      "--repo", "owner/repo",
      "--asset", "custom.dmg",
      "--target", "/tmp/custom-tool",
      "--team-id", "TEAMID",
      "--current-version", "v1.2.3",
    ])

    let updateOptions = options.updateOptions(
      log: { message in _ = message },
      dryRun: true)

    #expect(updateOptions.config.repo == "owner/repo")
    #expect(updateOptions.config.assetName == "custom.dmg")
    #expect(updateOptions.config.binary == "custom-tool")
    #expect(updateOptions.config.teamID == "TEAMID")
    #expect(updateOptions.config.currentVersion == "v1.2.3")
    #expect(updateOptions.targetPath == "/tmp/custom-tool")
    #expect(updateOptions.dryRun)
  }

  @Test
  static func updateOptionsUsesInjectedDiagnosticLog() throws {
    var diagnostics: [String] = []
    let options = try UpdateCommandOptions.parse([])

    let updateOptions = options.updateOptions { message in
      diagnostics.append(message)
    }
    updateOptions.log("update: diagnostic")

    #expect(diagnostics == ["update: diagnostic"])
  }

  @Test
  static func cachePruneRunnerPrintsSummaryAfterEviction() throws {
    try withTemporaryDirectory { directory in
      let oldFile = directory.appendingPathComponent("old.bin")
      let newFile = directory.appendingPathComponent("new.bin")
      try writeBytes(64, to: oldFile)
      try writeBytes(32, to: newFile)
      try setModificationDate(100, for: oldFile)
      try setModificationDate(200, for: newFile)
      var messages: [String] = []
      var errors: [String] = []
      let diagnostics = CachePruneDiagnostics()

      try runCachePrune(
        path: directory.path,
        maxBytes: 32,
        diagnostics: diagnostics,
        log: { message in messages.append(message) },
        logError: { message in errors.append(message) })

      #expect(messages == ["cache prune: evicted 1 entry, 64 bytes; remaining 32 bytes"])
      #expect(errors.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: oldFile.path))
      #expect(FileManager.default.fileExists(atPath: newFile.path))
    }
  }

  @Test
  static func cachePruneRunnerReportsErrorsThroughInjectedLogger() throws {
    try withTemporaryDirectory { directory in
      let missingPath = directory.appendingPathComponent("missing").path
      var messages: [String] = []
      var errors: [String] = []

      #expect(throws: ExitCode.self) {
        try runCachePrune(
          path: missingPath,
          maxBytes: 1,
          diagnostics: CachePruneDiagnostics(),
          log: { message in messages.append(message) },
          logError: { message in errors.append(message) })
      }

      #expect(messages.isEmpty)
      #expect(errors == ["cache prune: missing path \(missingPath)"])
    }
  }

  private static func withTemporaryDirectory(_ run: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-maint-runners-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      removeTemporaryDirectory(directory)
    }
    try run(directory)
  }

  private static func removeTemporaryDirectory(_ directory: URL) {
    let removalResult = Result {
      try FileManager.default.removeItem(at: directory)
    }
    if case .failure(let error) = removalResult {
      Issue.record("could not remove temporary directory \(directory.path): \(error)")
    }
  }

  private static func writeBytes(_ count: Int, to url: URL) throws {
    let data = Data(repeating: 1, count: count)
    try data.write(to: url)
  }

  private static func setModificationDate(_ timestamp: TimeInterval, for url: URL) throws {
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: timestamp)],
      ofItemAtPath: url.path)
  }
}
