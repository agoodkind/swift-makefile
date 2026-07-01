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

/// The dead-code coverage guardrails: the make-path compile surfaces refuse
/// without a gate, and the Xcode scan builds coverage options from the same
/// environment variables the make coverage command used.
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
  static func coverageBuildOptionsReadXcodeCoverageEnvironment() throws {
    try withUngatedDirectory { root in
      let saved = Environment.snapshot([
        "SWIFT_MK_DERIVED_DATA", "SWIFT_XCODE_GENERATOR",
        "SWIFT_XCODE_COVERAGE_CONFIGURATION", "SWIFT_XCODE_BUILD_SETTINGS",
      ])
      defer { saved.restore() }
      let derivedData = root + "/.derived-data"
      setenv("SWIFT_MK_DERIVED_DATA", derivedData, 1)
      setenv("SWIFT_XCODE_GENERATOR", Toolchain.Generator.xcodegen.rawValue, 1)
      setenv("SWIFT_XCODE_COVERAGE_CONFIGURATION", "Profile", 1)
      setenv(
        "SWIFT_XCODE_BUILD_SETTINGS",
        "SMC_FAN_HELPER_APP=/tmp/Helper.app OTHER_LDFLAGS=-ObjC",
        1)

      let options = DeadcodeScan.coverageBuildOptions(
        path: "App.xcodeproj",
        isWorkspace: false,
        packageTargets: ["AppPackage"])

      #expect(options.containerPath == "App.xcodeproj")
      #expect(!options.isWorkspace)
      #expect(options.generator == .xcodegen)
      #expect(options.configuration == "Profile")
      #expect(options.derivedDataPath == derivedData)
      #expect(options.packageTargetNames == Set(["AppPackage"]))
      #expect(options.extraSettings["SMC_FAN_HELPER_APP"] == "/tmp/Helper.app")
      #expect(options.extraSettings["OTHER_LDFLAGS"] == "-ObjC")
      #expect(options.environment["SWIFT_MK_RESULT_BUNDLE_DIR"] == derivedData + "/ResultBundles")
      let xcconfigPath = try #require(options.environment["XCODE_XCCONFIG_FILE"])
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
        path: "Missing.xcodeproj",
        isWorkspace: false,
        packageTargets: [],
        rawPath: root + "/.make/periphery.raw.out")
      // A failed coverage build returns nil, so scanProject never reaches the
      // periphery scan, and the raw file carries the hard-fail status escalation.
      #expect(result == nil)
    }
  }

  @Test
  static func ensureIndexStoreFailsClosedWithoutCoverageEntries() throws {
    try withUngatedDirectory { root in
      let saved = Environment.snapshot([
        "SWIFT_MK_DERIVED_DATA", "SWIFT_XCODE_GENERATOR",
      ])
      defer { saved.restore() }
      setenv("SWIFT_MK_DERIVED_DATA", root + "/.derived-data", 1)
      setenv("SWIFT_XCODE_GENERATOR", Toolchain.Generator.xcodegen.rawValue, 1)
      Capture.ensureMakeDir()
      let result = DeadcodeScan.ensureIndexStore(
        path: "Missing.xcodeproj",
        isWorkspace: false,
        packageTargets: [],
        rawPath: root + "/.make/periphery.raw.out")
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
