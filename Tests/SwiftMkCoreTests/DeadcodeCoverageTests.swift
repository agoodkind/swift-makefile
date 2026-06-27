//
//  DeadcodeCoverageTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - DeadcodeCoverageTests

/// The dead-code coverage guardrails: the compile surfaces refuse without a gate,
/// the in-gate capability authorizes the coverage build past the gate-proof check,
/// the coverage callback receives the signing-disabled environment, and a failed
/// coverage build fails closed before any scan.
@Suite(.serialized)
enum DeadcodeCoverageTests {
  @Test
  static func compileSurfacesRefuseWithoutAGate() throws {
    try withUngatedDirectory { root in
      let request = Toolchain.Request(
        generator: .tuist, scheme: "App", configuration: "Debug", workspace: "App.xcworkspace")
      #expect(Toolchain.buildForTesting(request) == GateProof.refusedExitStatus)
      #expect(Toolchain.analyze(request) == GateProof.refusedExitStatus)
      #expect(
        Toolchain.buildWritingLog(request, logPath: root + "/build.log")
          == GateProof.refusedExitStatus)
    }
  }

  @Test
  static func authorizedCoverageBuildSkipsTheGateProof() throws {
    try withUngatedDirectory { _ in
      // The authorization, not a gate ancestor, admits this compile: with a forbidden
      // signing setting it reaches the signing rejection (64) rather than the
      // gate-proof refusal (70), proving it skipped the GateProof check.
      let request = Toolchain.Request(
        generator: .tuist,
        scheme: "App",
        workspace: "App.xcworkspace",
        extraSettings: ["CODE_SIGN_IDENTITY": "Apple Development"])
      let status = Toolchain.buildForTesting(
        request, authorization: DeadcodeCoverageAuthorization(), environment: [:])
      #expect(status == Toolchain.signingOverrideRejectionStatus)
    }
  }

  @Test
  static func coverageCallbackReceivesSigningDisabledEnvironment() throws {
    try withUngatedDirectory { root in
      let saved = Environment.snapshot(["SWIFT_MK_DERIVED_DATA"])
      defer { saved.restore() }
      let derivedData = root + "/.derived-data"
      setenv("SWIFT_MK_DERIVED_DATA", derivedData, 1)
      Capture.ensureMakeDir()

      let capturedEnvironment = Box<[String: String]>([:])
      let callbackRan = Box(false)
      let result = DeadcodeScan.ensureIndexStore(
        rawPath: root + "/.make/periphery.raw.out"
      ) { _, environment in
        callbackRan.value = true
        capturedEnvironment.value = environment
        return DeadcodeCoverageResult(status: 0, output: "")
      }
      // No real index store is produced, so the locate step fails closed and returns
      // nil; the captured environment is what this test inspects.
      #expect(result == nil)
      #expect(callbackRan.value)
      let captured = capturedEnvironment.value
      let xcconfigPath = try #require(captured["XCODE_XCCONFIG_FILE"])
      #expect(captured["SWIFT_MK_RESULT_BUNDLE_DIR"] == derivedData + "/ResultBundles")
      let contents = try String(contentsOfFile: xcconfigPath, encoding: .utf8)
      #expect(contents.contains("CODE_SIGNING_ALLOWED = NO"))
      #expect(contents.contains("OBJROOT = \(derivedData)/DeadcodeBuild/Intermediates.noindex"))
      #expect(!contents.contains("SYMROOT ="))
    }
  }

  @Test
  static func failingCoverageBuildFailsClosed() throws {
    try withUngatedDirectory { root in
      let saved = Environment.snapshot(["SWIFT_MK_DERIVED_DATA"])
      defer { saved.restore() }
      setenv("SWIFT_MK_DERIVED_DATA", root + "/.derived-data", 1)
      Capture.ensureMakeDir()
      let result = DeadcodeScan.ensureIndexStore(
        rawPath: root + "/.make/periphery.raw.out"
      ) { _, _ in
        DeadcodeCoverageResult(status: 65, output: "the coverage build failed")
      }
      // A failed coverage build returns nil, so scanProject never reaches the
      // periphery scan, and the raw file carries the hard-fail status escalation.
      #expect(result == nil)
    }
  }

  @Test
  static func ensureIndexStoreFailsClosedWithoutCoverageOrBuildCommand() throws {
    try withUngatedDirectory { root in
      let saved = Environment.snapshot([
        "SWIFT_MK_DERIVED_DATA", "SWIFT_DEADCODE_BUILD_CMD", "SWIFT_BUILD_CMD",
      ])
      defer { saved.restore() }
      setenv("SWIFT_MK_DERIVED_DATA", root + "/.derived-data", 1)
      unsetenv("SWIFT_DEADCODE_BUILD_CMD")
      unsetenv("SWIFT_BUILD_CMD")
      Capture.ensureMakeDir()
      let result = DeadcodeScan.ensureIndexStore(
        rawPath: root + "/.make/periphery.raw.out", coverage: nil)
      #expect(result == nil)
    }
  }

  // MARK: helpers

  /// Run `body` in a temp directory marked as the swift-mk root, so a compile
  /// surface that consults `GateProof` finds no stamp and refuses regardless of
  /// whether a real `make` is an ancestor of the test process.
  private static func withUngatedDirectory(_ body: (String) throws -> Void) throws {
    try TestGlobalLock.withLock {
      try withUngatedDirectoryLocked(body)
    }
  }

  private static func withUngatedDirectoryLocked(_ body: (String) throws -> Void) throws {
    let manager = FileManager.default
    let root = NSTemporaryDirectory() + "swiftmk-deadcov-" + UUID().uuidString
    try manager.createDirectory(atPath: root, withIntermediateDirectories: true)
    let saved = Environment.snapshot(["SWIFT_MK_ROOT"])
    let savedCwd = manager.currentDirectoryPath
    defer {
      saved.restore()
      manager.changeCurrentDirectoryPath(savedCwd)
      removeTemporary(root)
    }
    setenv("SWIFT_MK_ROOT", root, 1)
    manager.changeCurrentDirectoryPath(root)
    try body(root)
  }
}
