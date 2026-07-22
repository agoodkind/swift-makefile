//
//  HelpFastPathTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-14.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - HelpFastPathTests

enum HelpFastPathTests {}

private let standaloneHelpFiles = Set([
  "logs/.run",
  "logs/.traceparent",
  "swift.mk",
])

private let tripwiredTools = ["swift", "swiftc", "gh", "curl"]

@Test
func standaloneHelpSkipsBootstrapWork() throws {
  let harness = try HelpFastPathHarness()
  defer { harness.cleanup() }

  let result = harness.runMake(["help"])
  #expect(result.status == 0, Comment(rawValue: result.combined))

  let directHelp = harness.runDirectSwiftMkHelp()
  #expect(directHelp.status == 0, Comment(rawValue: directHelp.combined))
  #expect(result.stdout == directHelp.stdout)
  #expect(try harness.tripwireLogLines().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: harness.swiftMkBinPath))
  #expect(try Set(harness.relativeMakeFiles()) == standaloneHelpFiles)
}

@Test
func mixedGoalRetainsNormalBootstrapPath() throws {
  let harness = try HelpFastPathHarness()
  defer { harness.cleanup() }

  let result = harness.runMake(["help", "lint-tools"])
  #expect(result.status != 0)

  let tripwireLogLines = try harness.tripwireLogLines()
  #expect(!tripwireLogLines.isEmpty)
  #expect(!Set(tripwireLogLines).isDisjoint(with: tripwiredTools))

  let fetchedFiles = try Set(harness.relativeMakeFiles())
  #expect(fetchedFiles.contains("swift-build.mk"))
  #expect(fetchedFiles.contains("xcconfig.mk"))
  #expect(fetchedFiles != standaloneHelpFiles)
}

@Test
func consumerHelpAppendStaysOnFastPath() throws {
  let appendedLine = "consumer-help-append"
  let harness = try HelpFastPathHarness(appendedHelpLine: appendedLine)
  defer { harness.cleanup() }

  let result = harness.runMake(["help"])
  #expect(result.status == 0, Comment(rawValue: result.combined))
  #expect(result.stdout.contains("Canonical entry points:"))
  #expect(result.stdout.contains(appendedLine))
  #expect(try harness.tripwireLogLines().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: harness.swiftMkBinPath))
  #expect(try Set(harness.relativeMakeFiles()) == standaloneHelpFiles)
}

// MARK: - HelpFastPathHarness

private struct HelpFastPathHarness {
  let root: URL
  let binDirectory: URL
  let logFile: URL
  let consumerRoot: URL
  let repositoryRoot: URL
  let swiftMkBinPath: String

  init(appendedHelpLine: String? = nil) throws {
    let fileManager = FileManager.default
    root = fileManager.temporaryDirectory.appendingPathComponent(
      "swift-mk-help-fast-path-\(UUID().uuidString)",
      isDirectory: true
    )
    binDirectory = root.appendingPathComponent("bin", isDirectory: true)
    logFile = root.appendingPathComponent("tripwire.log")
    consumerRoot = root.appendingPathComponent("consumer", isDirectory: true)
    repositoryRoot = helpFastPathRepositoryRoot()
    swiftMkBinPath = consumerRoot.appendingPathComponent(".make/missing/swift-mk").path

    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: consumerRoot, withIntermediateDirectories: true)
    try installBootstrap()
    try installConsumerMakefile(appendedHelpLine: appendedHelpLine)
    try installTripwires()
  }

  func cleanup() {
    do {
      try FileManager.default.removeItem(at: root)
    } catch {
      Output.warning("help fast-path cleanup failed: \(error.localizedDescription)")
    }
  }

  func runMake(_ goals: [String]) -> Shell.Result {
    var arguments = ["--no-print-directory", "-C", consumerRoot.path]
    arguments.append(contentsOf: goals)
    arguments.append("SWIFT_MK_DEV_DIR=\(repositoryRoot.path)")
    arguments.append("SWIFT_MK_BIN=\(swiftMkBinPath)")
    arguments.append("SWIFT_MK_MODULES=swift-build.mk xcconfig.mk")
    return Shell.run("make", arguments, environment: environment)
  }

  func runDirectSwiftMkHelp() -> Shell.Result {
    let swiftMkPath = repositoryRoot.appendingPathComponent("swift.mk").path
    let arguments = [
      "--no-print-directory",
      "-C",
      consumerRoot.path,
      "-f",
      swiftMkPath,
      "help",
      "SWIFT_MK_DEV_DIR=\(repositoryRoot.path)",
      "SWIFT_MK_BIN=\(swiftMkBinPath)",
      "SWIFT_MK_MODULES=swift-build.mk xcconfig.mk",
    ]
    return Shell.run("make", arguments, environment: environment)
  }

  func tripwireLogLines() throws -> [String] {
    guard FileManager.default.fileExists(atPath: logFile.path) else {
      return []
    }
    let contents = try String(contentsOf: logFile, encoding: .utf8)
    return contents.split(separator: "\n").map(String.init)
  }

  func relativeMakeFiles() throws -> [String] {
    let makeRoot = consumerRoot.appendingPathComponent(".make", isDirectory: true)
    guard FileManager.default.fileExists(atPath: makeRoot.path) else {
      return []
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: makeRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
      )
    else {
      return []
    }

    let standardizedMakeRoot = makeRoot.standardizedFileURL.path
    var files: [String] = []
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else {
        continue
      }
      let standardizedFilePath = fileURL.standardizedFileURL.path
      files.append(
        standardizedFilePath.replacingOccurrences(of: standardizedMakeRoot + "/", with: "")
      )
    }
    return files.sorted()
  }

  private var environment: [String: String] {
    [
      "PATH": binDirectory.path + ":" + ProcessInfo.processInfo.environment["PATH", default: ""],
      "SWIFT_MK_HELP_TRIPWIRE_LOG": logFile.path,
    ]
  }

  private func installBootstrap() throws {
    let bootstrapSource = repositoryRoot.appendingPathComponent("bootstrap.mk")
    let bootstrapDestination = consumerRoot.appendingPathComponent("bootstrap.mk")
    try FileManager.default.copyItem(at: bootstrapSource, to: bootstrapDestination)
  }

  private func installConsumerMakefile(appendedHelpLine: String? = nil) throws {
    var makefile = """
      SWIFT_MK_MODULES := swift-build.mk xcconfig.mk
      SWIFT_BUILD_CMD := printf 'build\\n'

      include bootstrap.mk
      """
    if let appendedHelpLine {
      makefile += """

        help::
        \t@printf '%s\\n' '\(appendedHelpLine)'
        """
    }
    let makefileURL = consumerRoot.appendingPathComponent("Makefile")
    try makefile.write(to: makefileURL, atomically: true, encoding: .utf8)
  }

  private func installTripwires() throws {
    let fixture = repositoryRoot.appendingPathComponent(
      "Tests/SwiftMkCoreTests/Fixtures/help-tool-tripwire.sh")
    for tool in tripwiredTools {
      let destination = binDirectory.appendingPathComponent(tool)
      try FileManager.default.createSymbolicLink(
        at: destination,
        withDestinationURL: fixture
      )
    }
  }
}

private func helpFastPathRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
