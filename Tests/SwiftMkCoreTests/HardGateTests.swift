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

/// `Lint.runHardBuildCheck`: caller narrows and the bypass token do not change the
/// gate, and the dead-code gate fails closed for an Xcode consumer whose coverage
/// build produces no index.
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

  /// The decoupled gate has no environment skip, on CI or off. A caller that owns
  /// gating elsewhere routes through `swift-mk build`, whose `GateProof` mark
  /// authorizes the compile through live process ancestry; environment values must
  /// never mint a receipt, because anyone can set them. This is the regression test
  /// for the skip that briefly existed and violated the gate contract.
  @Test
  static func ciEnvironmentAndSkipFlagDoNotSkipTheDecoupledGate() throws {
    try GatedBuildHarness.run(failSwiftlint: true) { setup in
      let saved = Environment.snapshot([
        "GITHUB_ACTIONS", "GITHUB_RUN_ID", "SWIFT_MK_SKIP_INLINE_GATES",
      ])
      defer { saved.restore() }
      setenv("GITHUB_ACTIONS", "true", 1)
      setenv("GITHUB_RUN_ID", "42", 1)
      setenv("SWIFT_MK_SKIP_INLINE_GATES", "1", 1)

      let compiled = Box(false)
      let status = GatedBuild.run(
        GatedBuild.Request(
          entry: "release build",
          context: PathContext(pwd: setup.root + "/", cwd: setup.root + "/")
        ) { _ in
          compiled.value = true
          return 0
        })

      // The harness plants a swiftlint violation, so the hard gate must fail and
      // the compile must never run; a compile here would mean the environment
      // skipped the gate.
      #expect(status == Toolchain.gateFailureStatus)
      #expect(!compiled.value)
    }
  }

  @Test
  static func deadcodeFailsClosedForXcodeRepoWithoutCoverage() throws {
    try GatedBuildHarness.run { setup in
      let saved = Environment.snapshot(["SWIFT_MK_XCODE_BUILD"])
      defer { saved.restore() }
      // Mark this an Xcode consumer and drop a project shell on disk. The gate must
      // fail rather than scan a missing or partial index.
      setenv("SWIFT_MK_XCODE_BUILD", "1", 1)
      try FileManager.default.createDirectory(
        atPath: setup.root + "/App.xcodeproj", withIntermediateDirectories: true)
      let ok = LintPolicy.deadcode(
        context: PathContext(pwd: setup.root + "/", cwd: setup.root + "/"))
      #expect(!ok)
    }
  }
}
