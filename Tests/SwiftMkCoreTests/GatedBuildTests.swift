//
//  GatedBuildTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - GatedBuildTests

/// `GatedBuild.run` orchestration: the gate runs before the compile, a gate failure
/// skips the compile and returns the gate-failure status, a passing gate returns the
/// compile's own status, and the signing override is applied before the compile.
@Suite(.serialized)
enum GatedBuildTests {
  @Test
  static func gateFailureSkipsTheCompileAndReturnsGateStatus() throws {
    // A failing generate hook fails the hard gate before any tool runs, so the
    // compile must never be invoked and the gate-failure status is returned.
    try GatedBuildHarness.run { setup in
      let compileRan = Box(false)
      let neverGenerate: @Sendable () -> Bool = { false }
      let status = GatedBuild.run(
        GatedBuild.Request(
          entry: "gated build",
          context: PathContext(pwd: setup.root + "/", cwd: setup.root + "/"),
          hooks: GatedBuild.Hooks(generate: neverGenerate)
        ) { _ in
          compileRan.value = true
          return 0
        })
      #expect(status == Toolchain.gateFailureStatus)
      #expect(!compileRan.value)
    }
  }

  @Test
  static func passingGateReturnsTheCompileStatus() throws {
    // The gate passes (fake tools report nothing), so `run` returns whatever the
    // compile returns, here a sentinel.
    try GatedBuildHarness.run { setup in
      let sentinel: Int32 = 7
      let status = GatedBuild.run(
        GatedBuild.Request(
          entry: "gated build",
          context: PathContext(pwd: setup.root + "/", cwd: setup.root + "/")
        ) { _ in sentinel })
      #expect(status == sentinel)
    }
  }

  @Test
  static func signingOverrideAppliedBeforeCompile() throws {
    // With a team set, the override is applied before the compile, so the compile
    // observes XCODE_XCCONFIG_FILE pointing at the swift-mk signing xcconfig.
    try GatedBuildHarness.run(signingTeam: "H3BMXM4W7H") { setup in
      let overrideAtCompile = Box("")
      let status = GatedBuild.run(
        GatedBuild.Request(
          entry: "gated build",
          context: PathContext(pwd: setup.root + "/", cwd: setup.root + "/")
        ) { _ in
          overrideAtCompile.value = Env.get("XCODE_XCCONFIG_FILE")
          return 0
        })
      #expect(status == 0)
      #expect(overrideAtCompile.value.hasSuffix("/signing.xcconfig"))
    }
  }
}
