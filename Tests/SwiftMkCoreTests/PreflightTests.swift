//
//  PreflightTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - PreflightTests

@Suite(.serialized)
enum PreflightTests {
  private static let verifyXcconfigKey = "SWIFT_MK_VERIFY_XCCONFIG"
  private static let verifyXcconfigHint =
    "copy Config/local.xcconfig.example and fill in DEVELOPMENT_TEAM"

  @Test
  static func missingReturnsAbsentRequirementsInOrder() {
    let requirements = [
      Preflight.Requirement(path: "Config/local.xcconfig", hint: "copy the example"),
      Preflight.Requirement(path: "Secrets/signing.p12", hint: "install signing input"),
      Preflight.Requirement(path: "Profiles/app.mobileprovision", hint: "download profile"),
    ]

    let missingRequirements = Preflight.missing(requirements) { path in
      path == "Secrets/signing.p12"
    }

    #expect(missingRequirements == [requirements[0], requirements[2]])
  }

  @Test
  static func failureMessageNamesMissingPathsAndHintsWithoutTypographicDashes() {
    let missingRequirements = [
      Preflight.Requirement(
        path: "Config/local.xcconfig",
        hint: "copy Config/local.xcconfig.example"),
      Preflight.Requirement(
        path: "Secrets/signing.p12",
        hint: "export the signing identity"),
    ]

    let message = Preflight.failureMessage(missingRequirements)

    #expect(message.contains("preflight: missing required operator files:"))
    #expect(message.contains("Config/local.xcconfig"))
    #expect(message.contains("copy Config/local.xcconfig.example"))
    #expect(message.contains("Secrets/signing.p12"))
    #expect(message.contains("export the signing identity"))
    #expect(!message.contains("\u{2014}"))
    #expect(!message.contains("\u{2013}"))
  }

  @Test
  static func preflightRequirementsIncludeDeclaredXcconfigPath() {
    let originalValue = savedEnvironmentValue(verifyXcconfigKey)
    defer {
      restoreEnvironmentValue(originalValue, forKey: verifyXcconfigKey)
    }

    setenv(verifyXcconfigKey, "Config/local.xcconfig", 1)

    let requirements = Lint.preflightRequirements()
    let expected = [
      Preflight.Requirement(
        path: "Config/local.xcconfig",
        hint: verifyXcconfigHint)
    ]
    #expect(requirements == expected)
  }

  @Test
  static func preflightRequirementsAreEmptyWhenXcconfigPathIsUnset() {
    let originalValue = savedEnvironmentValue(verifyXcconfigKey)
    defer {
      restoreEnvironmentValue(originalValue, forKey: verifyXcconfigKey)
    }

    unsetenv(verifyXcconfigKey)

    #expect(Lint.preflightRequirements().isEmpty)
  }

  @Test
  static func checkFilesReportsAbsentPathsAndPassesWhenAllArePresent() throws {
    let directory = try makeTemporaryDirectory()
    defer {
      do {
        try FileManager.default.removeItem(atPath: directory)
      } catch {
        Output.warning("cleanup failed: \(error.localizedDescription)")
      }
    }

    let presentPath = (directory as NSString).appendingPathComponent("present.txt")
    let absentPath = (directory as NSString).appendingPathComponent("absent.txt")
    try "present\n".write(toFile: presentPath, atomically: true, encoding: .utf8)

    let failed = Preflight.checkFiles([
      Preflight.Requirement(path: presentPath, hint: "already created"),
      Preflight.Requirement(path: absentPath, hint: "create the absent file"),
    ])

    #expect(!failed.ok)
    #expect(failed.message.contains(absentPath))

    try "present\n".write(toFile: absentPath, atomically: true, encoding: .utf8)
    let passed = Preflight.checkFiles([
      Preflight.Requirement(path: presentPath, hint: "already created"),
      Preflight.Requirement(path: absentPath, hint: "already created"),
    ])

    #expect(passed.ok)
    #expect(passed.message.isEmpty)
  }

  private static func makeTemporaryDirectory() throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-preflight-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.path
  }

  private static func savedEnvironmentValue(_ key: String) -> String? {
    guard let value = getenv(key) else {
      return nil
    }
    return String(cString: value)
  }

  private static func restoreEnvironmentValue(_ value: String?, forKey key: String) {
    guard let value else {
      unsetenv(key)
      return
    }
    setenv(key, value, 1)
  }
}
