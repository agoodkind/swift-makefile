//
//  NoMakeGatedBuildHarnessTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - NoMakeGatedBuildHarnessTests

/// The decoupled proof: a temp checkout links `SwiftMkCore`, puts fake
/// `swiftlint`/`periphery`/`osv-scanner`/`swift-format`/`xcodebuild` on `PATH`, and
/// runs `GatedBuild.run` with no `make` ancestor. The fakes make the gate pass, so
/// the consumer's compile runs and the fake xcodebuild leaves its marker; a lint
/// violation blocks the compile; a direct `Toolchain.build(_:)` outside the gate is
/// refused.
@Suite(.serialized)
enum NoMakeGatedBuildHarnessTests {
  @Test
  static func gatePassesThenCompileRunsWithoutMake() throws {
    try GatedBuildHarness.run { setup in
      let status = GatedBuild.run(
        GatedBuild.Request(
          entry: "harness build",
          context: PathContext(pwd: setup.root + "/", cwd: setup.root + "/")
        ) { receipt in
          Toolchain.build(GatedBuildHarness.compileRequest(), receipt: receipt)
        })
      #expect(status == 0)
      #expect(FileManager.default.fileExists(atPath: setup.xcodebuildMarker))
    }
  }

  @Test
  static func lintViolationBlocksTheCompile() throws {
    try GatedBuildHarness.run(failSwiftlint: true) { setup in
      let status = GatedBuild.run(
        GatedBuild.Request(
          entry: "harness build",
          context: PathContext(pwd: setup.root + "/", cwd: setup.root + "/")
        ) { receipt in
          Toolchain.build(GatedBuildHarness.compileRequest(), receipt: receipt)
        })
      #expect(status == Toolchain.gateFailureStatus)
      // The gate failed, so the compile never ran and the fake xcodebuild left no
      // marker.
      #expect(!FileManager.default.fileExists(atPath: setup.xcodebuildMarker))
    }
  }

  @Test
  static func directProductBuildIsRefusedOutsideTheGate() throws {
    try GatedBuildHarness.run { _ in
      // No receipt, no make ancestor, no stamp in this temp checkout: the make-path
      // product build refuses rather than producing an ungated artifact.
      let status = Toolchain.build(GatedBuildHarness.compileRequest())
      #expect(status == GateProof.refusedExitStatus)
    }
  }
}
