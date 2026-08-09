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

  /// The release path compiles a commit CI already gated, on a runner with no lint
  /// tooling. It says so with `SWIFT_MK_SKIP_INLINE_GATES=1`, and that is honored only
  /// on CI, so the same variable on a developer's machine cannot compile past the gate.
  @Test
  static func theGateIsSkippedOnlyForAnOptedInCIRun() {
    #expect(
      GatedBuild.skipsHardGate(
        githubActions: "true", githubRunId: "42", skipInlineGates: "1"))
    // Off CI the flag alone means nothing, which is what keeps it from becoming the
    // bypass the hard gate refuses every other narrowing knob to be.
    #expect(
      !GatedBuild.skipsHardGate(
        githubActions: "", githubRunId: "", skipInlineGates: "1"))
    // `GITHUB_ACTIONS` without a run id is not a CI run.
    #expect(
      !GatedBuild.skipsHardGate(
        githubActions: "true", githubRunId: "", skipInlineGates: "1"))
    // A CI run that did not opt in is still gated.
    #expect(
      !GatedBuild.skipsHardGate(
        githubActions: "true", githubRunId: "42", skipInlineGates: ""))
  }

  /// Generation runs inside the hard gate, and the compile reads its output, so a
  /// skipped gate must still generate. Otherwise the release build fails on missing
  /// generated sources instead of compiling.
  @Test
  static func skippingTheGateStillGenerates() throws {
    try GatedBuildHarness.run(failSwiftlint: true) { setup in
      let saved = Environment.snapshot([
        "GITHUB_ACTIONS", "GITHUB_RUN_ID", "SWIFT_MK_SKIP_INLINE_GATES",
      ])
      defer { saved.restore() }
      setenv("GITHUB_ACTIONS", "true", 1)
      setenv("GITHUB_RUN_ID", "42", 1)
      setenv("SWIFT_MK_SKIP_INLINE_GATES", "1", 1)

      let generated = Box(false)
      let compiled = Box(false)
      let hooks = GatedBuild.Hooks {
        generated.value = true
        return true
      }
      let status = GatedBuild.run(
        GatedBuild.Request(
          entry: "release build",
          context: PathContext(pwd: setup.root + "/", cwd: setup.root + "/"),
          hooks: hooks
        ) { _ in
          compiled.value = true
          return 0
        })

      // The swiftlint violation the harness plants would fail the gate, so a compile
      // here proves the gate was skipped rather than passed.
      #expect(status == 0)
      #expect(generated.value)
      #expect(compiled.value)
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
