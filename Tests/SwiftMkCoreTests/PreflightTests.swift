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
  static func preflightRequirementsDoNotRequireDeclaredXcconfigPath() {
    let originalValue = savedEnvironmentValue(verifyXcconfigKey)
    defer {
      restoreEnvironmentValue(originalValue, forKey: verifyXcconfigKey)
    }

    setenv(verifyXcconfigKey, "Config/local.xcconfig", 1)

    #expect(Lint.preflightRequirements().isEmpty)
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

  @Test
  static func railIsInertWhenBothCommandsAreEmpty() {
    var checkCalls = 0
    var ensureCalls = 0

    let outcome = Preflight.ensureConsumerRequirement(
      check: "   ",
      ensure: "",
      runCheck: { _ in
        checkCalls += 1
        return Preflight.CheckRun(status: 0, output: "")
      },
      runEnsure: { _ in
        ensureCalls += 1
        return 0
      }
    )

    #expect(outcome == .inert)
    #expect(checkCalls == 0)
    #expect(ensureCalls == 0)
  }

  @Test
  static func railPassesSilentlyWhenCheckSucceeds() {
    var checkCalls = 0
    var ensureCalls = 0

    let outcome = Preflight.ensureConsumerRequirement(
      check: "xcrun --find tool",
      ensure: "download tool",
      runCheck: { _ in
        checkCalls += 1
        return Preflight.CheckRun(status: 0, output: "/usr/bin/tool")
      },
      runEnsure: { _ in
        ensureCalls += 1
        return 0
      }
    )

    #expect(outcome == .passed)
    #expect(checkCalls == 1)
    #expect(ensureCalls == 0)
  }

  @Test
  static func railEnsuresOnMissThenContinuesWhenRecheckPasses() {
    var checkCalls = 0
    var ensureCommands: [String] = []

    let outcome = Preflight.ensureConsumerRequirement(
      check: "xcrun --find tool",
      ensure: "download tool",
      runCheck: { _ in
        checkCalls += 1
        let missing = checkCalls == 1
        return Preflight.CheckRun(status: missing ? 1 : 0, output: missing ? "not found" : "")
      },
      runEnsure: { command in
        ensureCommands.append(command)
        return 0
      }
    )

    #expect(outcome == .ensured)
    #expect(checkCalls == 2)
    #expect(ensureCommands == ["download tool"])
  }

  @Test
  static func railFailsLoudWithVerbatimOutputWhenRecheckStillFails() {
    var checkCalls = 0
    var ensureCalls = 0

    let outcome = Preflight.ensureConsumerRequirement(
      check: "xcrun --find tool",
      ensure: "download tool",
      runCheck: { _ in
        checkCalls += 1
        return Preflight.CheckRun(status: 69, output: "xcrun: error: unable to find utility")
      },
      runEnsure: { _ in
        ensureCalls += 1
        return 0
      }
    )

    let expectedMessage =
      "preflight: check failed (exit 69): xcrun --find tool\n"
      + "xcrun: error: unable to find utility"
    #expect(outcome == .failed(message: expectedMessage))
    #expect(checkCalls == 2)
    #expect(ensureCalls == 1)
  }

  @Test
  static func railFailsImmediatelyWhenCheckFailsWithoutEnsure() {
    var ensureCalls = 0

    let outcome = Preflight.ensureConsumerRequirement(
      check: "test -f required.txt",
      ensure: "",
      runCheck: { _ in
        Preflight.CheckRun(status: 1, output: "")
      },
      runEnsure: { _ in
        ensureCalls += 1
        return 0
      }
    )

    #expect(outcome == .failed(message: "preflight: check failed (exit 1): test -f required.txt"))
    #expect(ensureCalls == 0)
  }

  @Test
  static func railRunsEnsureEveryTimeWhenCheckIsEmpty() {
    var ensureCalls = 0

    let succeeded = Preflight.ensureConsumerRequirement(
      check: "",
      ensure: "idempotent provision",
      runCheck: { _ in
        Preflight.CheckRun(status: 1, output: "never called")
      },
      runEnsure: { _ in
        ensureCalls += 1
        return 0
      }
    )
    #expect(succeeded == .ensured)
    #expect(ensureCalls == 1)

    let failed = Preflight.ensureConsumerRequirement(
      check: "",
      ensure: "idempotent provision",
      runCheck: { _ in
        Preflight.CheckRun(status: 1, output: "never called")
      },
      runEnsure: { _ in
        ensureCalls += 1
        return 7
      }
    )
    #expect(failed == .failed(message: "preflight: ensure command failed: idempotent provision"))
    #expect(ensureCalls == 2)
  }

  @Test
  static func railEnsureFailureFailsLoudBeforeAnyRecheck() {
    var checkCalls = 0

    let outcome = Preflight.ensureConsumerRequirement(
      check: "xcrun --find tool",
      ensure: "download tool",
      runCheck: { _ in
        checkCalls += 1
        return Preflight.CheckRun(status: 1, output: "not found")
      },
      runEnsure: { _ in 3 }
    )

    #expect(outcome == .failed(message: "preflight: ensure command failed: download tool"))
    #expect(checkCalls == 1)
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
