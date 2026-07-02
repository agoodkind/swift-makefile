//
//  ToolchainBuildCoverageTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ToolchainBuildCoverageTests

@Suite(.serialized)
enum ToolchainBuildCoverageTests {
  @Test
  static func wipeableDerivedDataAcceptsAStrictProjectSubdirectory() {
    #expect(Toolchain.isWipeableDerivedData("/proj/build/DerivedData", relativeTo: "/proj"))
    #expect(Toolchain.isWipeableDerivedData("/proj/.derived-data", relativeTo: "/proj"))
  }

  @Test
  static func wipeableDerivedDataRejectsBroadPaths() {
    // The project root itself, a parent, a sibling, a home directory, and root must
    // never be wiped, so a misconfigured SWIFT_MK_DERIVED_DATA cannot rm -rf them.
    #expect(!Toolchain.isWipeableDerivedData("/proj", relativeTo: "/proj"))
    #expect(!Toolchain.isWipeableDerivedData("/", relativeTo: "/proj"))
    #expect(!Toolchain.isWipeableDerivedData("/Users/dev", relativeTo: "/proj"))
    #expect(!Toolchain.isWipeableDerivedData("/proj-other/build", relativeTo: "/proj"))
    #expect(!Toolchain.isWipeableDerivedData("/proj/build/../../etc", relativeTo: "/proj"))
  }

  @Test
  static func buildCoverageEntriesRunsEveryEntryWithDestinationAndResultBundle() throws {
    try GatedBuildHarness.run { setup in
      let entries = [
        DeadcodeCoverageEntry(scheme: "App", platform: .macosx),
        DeadcodeCoverageEntry(scheme: "App", platform: .maccatalyst),
        DeadcodeCoverageEntry(scheme: "Agent", platform: .macosx),
      ]
      let resultBundleRoot = setup.root + "/ResultBundles"
      var options = Toolchain.CoverageBuildOptions()
      options.containerPath = "App.xcworkspace"
      options.isWorkspace = true
      options.generator = .tuist
      options.configuration = "Debug"
      options.derivedDataPath = setup.root + "/DerivedData"
      options.extraSettings = ["COMPILER_INDEX_STORE_ENABLE": "YES"]
      options.environment = ["SWIFT_MK_RESULT_BUNDLE_DIR": resultBundleRoot]

      let result = Toolchain.buildCoverageEntries(entries, options: options)

      let invocations = try readXcodebuildInvocations(setup.xcodebuildArgumentsLog)
      let resultBundlePaths = try invocations.map { arguments in
        try #require(resultBundlePath(in: arguments))
      }

      #expect(result.status == 0)
      #expect(result.output.contains("fake xcodebuild scheme=App"))
      #expect(result.output.contains("fake xcodebuild scheme=Agent"))
      #expect(invocations.count == entries.count)
      #expect(
        resultBundlePaths == [
          resultBundleRoot + "/macosx/App-Debug.xcresult",
          resultBundleRoot + "/maccatalyst/App-Debug.xcresult",
          resultBundleRoot + "/macosx/Agent-Debug.xcresult",
        ])
      #expect(Set(resultBundlePaths).count == resultBundlePaths.count)
      assertInvocation(
        invocations[0],
        containsDestination: Toolchain.coverageDestination(for: .macosx),
        containerFlag: "-workspace")
      assertInvocation(
        invocations[1],
        containsDestination: Toolchain.coverageDestination(for: .maccatalyst),
        containerFlag: "-workspace")
      assertInvocation(
        invocations[2],
        containsDestination: Toolchain.coverageDestination(for: .macosx),
        containerFlag: "-workspace")
    }
  }

  @Test
  static func buildCoverageEntriesReturnsFirstNonzeroStatus() throws {
    try GatedBuildHarness.run { setup in
      setenv("FAKE_XCODEBUILD_FAIL_SCHEME", "Agent", 1)
      setenv("FAKE_XCODEBUILD_FAIL_STATUS", "42", 1)
      let entries = [
        DeadcodeCoverageEntry(scheme: "App", platform: .macosx),
        DeadcodeCoverageEntry(scheme: "Agent", platform: .macosx),
        DeadcodeCoverageEntry(scheme: "Helper", platform: .macosx),
      ]
      var options = Toolchain.CoverageBuildOptions()
      options.containerPath = "App.xcodeproj"
      options.isWorkspace = false
      options.generator = .xcodegen
      options.configuration = "Debug"
      options.derivedDataPath = setup.root + "/DerivedData"

      let result = Toolchain.buildCoverageEntries(entries, options: options)
      let invocations = try readXcodebuildInvocations(setup.xcodebuildArgumentsLog)

      #expect(result.status == 42)
      #expect(invocations.count == entries.count)
      #expect(result.output.contains("fake xcodebuild scheme=Helper"))
      assertInvocation(
        invocations[0],
        containsDestination: Toolchain.coverageDestination(for: .macosx),
        containerFlag: "-project")
    }
  }

  @Test
  static func buildCoverageEntriesOmitsEmptyDerivedDataPath() throws {
    try GatedBuildHarness.run { setup in
      let entries = [
        DeadcodeCoverageEntry(scheme: "App", platform: .macosx)
      ]
      var options = Toolchain.CoverageBuildOptions()
      options.containerPath = "App.xcworkspace"
      options.isWorkspace = true
      options.generator = .tuist
      options.configuration = "Debug"

      let result = Toolchain.buildCoverageEntries(entries, options: options)
      let invocations = try readXcodebuildInvocations(setup.xcodebuildArgumentsLog)

      #expect(result.status == 0)
      #expect(invocations.count == entries.count)
      #expect(!invocations[0].contains("-derivedDataPath"))
    }
  }

  private static func assertInvocation(
    _ arguments: [String],
    containsDestination destination: String,
    containerFlag: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(arguments.contains(containerFlag), sourceLocation: sourceLocation)
    #expect(arguments.contains("-destination"), sourceLocation: sourceLocation)
    #expect(arguments.contains(destination), sourceLocation: sourceLocation)
    #expect(arguments.contains("-derivedDataPath"), sourceLocation: sourceLocation)
    #expect(arguments.last == "build-for-testing", sourceLocation: sourceLocation)
  }

  private static func resultBundlePath(in arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: "-resultBundlePath") else {
      return nil
    }
    let pathIndex = arguments.index(after: flagIndex)
    guard pathIndex < arguments.endIndex else {
      return nil
    }
    return arguments[pathIndex]
  }

  private static func readXcodebuildInvocations(_ path: String) throws -> [[String]] {
    let lines = try readLines(path)
    var invocations: [[String]] = []
    var current: [String] = []
    for line in lines {
      if line == "BEGIN" {
        current = []
      } else if line == "END" {
        invocations.append(current)
      } else {
        current.append(line)
      }
    }
    return invocations
  }

  private static func readLines(_ path: String) throws -> [String] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    return text.split(separator: "\n").map(String.init)
  }
}
