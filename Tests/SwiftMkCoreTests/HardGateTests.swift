//
//  HardGateTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - HardGateTests

/// `Lint.runHardBuildCheck`: caller narrowers and the bypass token do not change the
/// gate, and the dead-code gate fails closed for an Xcode consumer that supplies no
/// coverage build.
@Suite(.serialized)
enum HardGateTests {
  @Test
  static func narrowersAndBypassDoNotChangeTheGate() throws {
    try GatedBuildHarness.run(failSwiftlint: true) { setup in
      let saved = Environment.snapshot(["BYPASS_CONFIRM"])
      defer { saved.restore() }
      // Try every narrower and the bypass: drop swiftlint from LINT_GATES, point the
      // targets elsewhere, and set a bypass token. The hard gate ignores all of them,
      // so the swiftlint violation still fails the gate.
      setenv("LINT_GATES", "lint-format", 1)
      setenv("SWIFTLINT_TARGETS", "/nonexistent", 1)
      setenv("LINT_FILES", "/nonexistent", 1)
      setenv("BYPASS_LINT", "any-token", 1)
      setenv("BYPASS_CONFIRM", "yes", 1)
      let ok = Lint.runHardBuildCheck(
        context: PathContext(pwd: setup.root + "/", cwd: setup.root + "/"),
        hooks: GatedBuild.Hooks())
      #expect(!ok)
    }
  }

  @Test
  static func passesWhenEveryFakeGateIsClean() throws {
    try GatedBuildHarness.run { setup in
      let ok = Lint.runHardBuildCheck(
        context: PathContext(pwd: setup.root + "/", cwd: setup.root + "/"),
        hooks: GatedBuild.Hooks())
      #expect(ok)
    }
  }

  @Test
  static func deadcodeFailsClosedForXcodeRepoWithoutCoverage() throws {
    try GatedBuildHarness.run { setup in
      let saved = Environment.snapshot(["SWIFT_MK_XCODE_BUILD"])
      defer { saved.restore() }
      // Mark this an Xcode consumer and drop a stray project on disk, but give no
      // coverage build (callback nil, no SWIFT_DEADCODE_BUILD_CMD). The gate must
      // fail rather than scan a missing or partial index.
      setenv("SWIFT_MK_XCODE_BUILD", "1", 1)
      try FileManager.default.createDirectory(
        atPath: setup.root + "/App.xcodeproj", withIntermediateDirectories: true)
      let ok = LintPolicy.deadcode(
        context: PathContext(pwd: setup.root + "/", cwd: setup.root + "/"),
        coverage: nil)
      #expect(!ok)
    }
  }
}
