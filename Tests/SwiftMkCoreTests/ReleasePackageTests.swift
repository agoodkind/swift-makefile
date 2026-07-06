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
