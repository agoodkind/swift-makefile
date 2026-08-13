//
//  ReleasePackageTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ReleasePackageTests

enum ReleasePackageTests {}

@Test
func releasePackageUsesLeanProductAndMovedVersionStamp() {
  let plan = ReleasePackage.plan(
    tag: "faketag-0000",
    distDir: "dist",
    signingEnginePath: ".make/swift-mk")

  #expect(plan.versionFile == "Sources/SwiftMkMaintCore/ReleaseVersion.swift")
  #expect(
    plan.buildArguments == [
      "build", "-c", "release", "--product", "swift-mk-maint", "--arch", "arm64",
    ])
  #expect(plan.builtProductName == "swift-mk-maint")
  #expect(plan.stagedBinaryName == "swift-mk")
  #expect(plan.assetName == "swift-mk_darwin_arm64.dmg")
}

@Test
func releasePackageBuildCarriesTheCompileCacheFlags() throws {
  let previousEnabled = ProcessInfo.processInfo.environment[
    "SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED"]
  let previousPath = ProcessInfo.processInfo.environment["SWIFT_MK_SWIFTPM_CACHE_PATH"]
  defer {
    restoreEnvironmentValue(previousEnabled, forKey: "SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED")
    restoreEnvironmentValue(previousPath, forKey: "SWIFT_MK_SWIFTPM_CACHE_PATH")
  }
  let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-release-cache-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
  defer {
    do {
      try FileManager.default.removeItem(at: cacheDirectory)
    } catch {
      Output.warning("cleanup failed: \(error.localizedDescription)")
    }
  }
  setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", "YES", 1)
  setenv("SWIFT_MK_SWIFTPM_CACHE_PATH", cacheDirectory.path, 1)

  let plan = ReleasePackage.plan(
    tag: "faketag-0000",
    distDir: "dist",
    signingEnginePath: ".make/swift-mk")
  let enabled = ReleasePackage.buildInvocationArguments(plan)

  #expect(enabled.starts(with: plan.buildArguments))
  #expect(enabled.contains("-explicit-module-build"))
  #expect(enabled.contains("-cas-path"))

  setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", "NO", 1)
  let disabled = ReleasePackage.buildInvocationArguments(plan)

  #expect(disabled == plan.buildArguments)
}

private func restoreEnvironmentValue(_ value: String?, forKey key: String) {
  guard let value else {
    unsetenv(key)
    return
  }
  setenv(key, value, 1)
}

@Test
func releasePackageStampsMaintVersionFileAndFailsWhenDevLiteralIsMissing() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-release-package-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer {
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      Output.warning("cleanup failed: \(error.localizedDescription)")
    }
  }
  let versionFile = directory.appendingPathComponent("ReleaseVersion.swift")
  try "public static let current = \"dev\"\n".write(
    to: versionFile, atomically: true, encoding: .utf8)

  try ReleasePackage.stampVersion(tag: "faketag-0000", versionFile: versionFile.path)

  let stamped = try String(contentsOf: versionFile, encoding: .utf8)
  #expect(stamped == "public static let current = \"faketag-0000\"\n")

  try "public static let current = \"old\"\n".write(
    to: versionFile, atomically: true, encoding: .utf8)
  #expect(throws: ReleasePackageError.versionStampFailed(versionFile.path, "faketag-0000")) {
    try ReleasePackage.stampVersion(tag: "faketag-0000", versionFile: versionFile.path)
  }
}

@Test
func releasePackageAcceptsAPrereleaseTagWithBuildMetadata() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-release-package-tag-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer {
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      Output.warning("cleanup failed: \(error.localizedDescription)")
    }
  }
  let versionFile = directory.appendingPathComponent("ReleaseVersion.swift")
  try "public static let current = \"dev\"\n".write(
    to: versionFile, atomically: true, encoding: .utf8)

  let tag = "26.7.26-pre.202607261401+c95d264"
  try ReleasePackage.stampVersion(tag: tag, versionFile: versionFile.path)

  let stamped = try String(contentsOf: versionFile, encoding: .utf8)
  #expect(stamped == "public static let current = \"\(tag)\"\n")
}
