//
//  SnapshotClearEngineTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-12.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - SnapshotClearEngineTests

/// The snapshot re-extract clears the prior engine tree before laying down the new
/// one, so a ref change or a migration from the old per-file `.make` cannot leave an
/// orphaned source the new snapshot no longer defines. This exercises the shell
/// `snapshot_clear_engine` helper in `scripts/swift-mk-sync.sh` directly: it must
/// remove engine content while preserving the generated runtime files a build depends
/// on.
enum SnapshotClearEngineTests {
  @Test
  static func clearRemovesOrphanEngineFilesButKeepsGeneratedRuntimeFiles() throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent(
      "swiftmk-snapshot-clear-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { removeTemporary(directory.path) }

    let makeDir = directory.appendingPathComponent(".make", isDirectory: true)

    // Engine content from a prior snapshot, which must be cleared.
    let orphanSource = makeDir.appendingPathComponent("Sources/SwiftMkCore/OrphanProbe.swift")
    let enginePackage = makeDir.appendingPathComponent("Package.swift")
    let engineModule = makeDir.appendingPathComponent("swift-build.mk")
    // Generated runtime files, which must survive.
    let buildLock = makeDir.appendingPathComponent("build.lock")
    let logsEntry = makeDir.appendingPathComponent("logs/run")
    let binary = makeDir.appendingPathComponent("swift-mk")
    let binaryKey = makeDir.appendingPathComponent("swift-mk.key")
    let devLink = makeDir.appendingPathComponent("dev/swift-makefile")
    let marker = makeDir.appendingPathComponent(".swift-mk-snapshot-ref")
    let snapshotLog = makeDir.appendingPathComponent("swift-mk-snapshot.log")
    // The gate proof authorizes every compile in the build that is running, and a
    // re-extract can happen mid-build when a consumer's generate step recurses into
    // make. Clearing it sent later compiles down the decoupled path, where a release
    // runner has no lint tools and the hard gate failed on missing binaries.
    let gateStamp = makeDir.appendingPathComponent(".gate/stamp")
    // The signing preflight writes this before the build and names it in
    // XCODE_XCCONFIG_FILE for the build's whole life. Losing it mid-build makes
    // xcodebuild report that the file cannot be opened and that every target needs a
    // development team, which reads as a signing misconfiguration rather than a
    // deleted file.
    let signingConfig = makeDir.appendingPathComponent(SigningBuildConfig.fileName)
    let engineFiles = [orphanSource, enginePackage, engineModule]
    let generatedFiles = [
      buildLock, logsEntry, binary, binaryKey, devLink, marker, snapshotLog, gateStamp,
      signingConfig,
    ]

    for fileURL in engineFiles + generatedFiles {
      try manager.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "x\n".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    let script = SnapshotClearEngineTests.repoRoot()
      .appendingPathComponent("scripts/swift-mk-sync.sh").path
    let command = #"source "${SCRIPT_PATH}"; snapshot_clear_engine "${MAKE_DIR}""#
    let result = Shell.run(
      "/bin/bash",
      ["-c", command],
      environment: [
        "SCRIPT_PATH": script,
        "MAKE_DIR": makeDir.path,
      ])
    #expect(result.status == 0)

    // Engine content is cleared, including the whole orphaned source subtree.
    for fileURL in engineFiles {
      #expect(!manager.fileExists(atPath: fileURL.path), "engine file survived: \(fileURL.path)")
    }
    #expect(!manager.fileExists(atPath: makeDir.appendingPathComponent("Sources").path))

    // Generated runtime files are preserved.
    for fileURL in generatedFiles {
      #expect(
        manager.fileExists(atPath: fileURL.path), "generated file cleared: \(fileURL.path)")
    }
  }

  /// The bootstrap swaps `.make` wholesale rather than clearing selectively: it stages
  /// a new tree, copies in only the names its preserve list enumerates, then moves the
  /// old directory away and deletes it. So the two lists must name the same runtime
  /// state, or a file survives one path and is destroyed by the other. That drift is
  /// what let a cold re-extract inside a consumer's nested `make generate` delete the
  /// gate stamp after the clear path had already been taught to keep it.
  @Test
  static func bootstrapPreservesEverythingTheClearPathPreserves() throws {
    let root = SnapshotClearEngineTests.repoRoot()
    let clearText = try String(
      contentsOf: root.appendingPathComponent("scripts/swift-mk-sync.sh"), encoding: .utf8)
    let bootstrapText = try String(
      contentsOf: root.appendingPathComponent("scripts/swift-mk-bootstrap.sh"), encoding: .utf8)

    // Names the clear path spares, read from the script rather than restated here, so
    // the assertion tracks the source instead of a copy that can go stale.
    let spared =
      clearText
      .components(separatedBy: "! -name ")
      .dropFirst()
      .map { $0.prefix { !$0.isWhitespace && $0 != "\\" } }
      .map(String.init)
      .filter { !$0.isEmpty }
    #expect(spared.contains(".gate"), "the clear path no longer spares .gate")
    #expect(
      spared.contains(SigningBuildConfig.fileName),
      "the clear path no longer spares \(SigningBuildConfig.fileName)")

    for name in spared {
      #expect(
        bootstrapText.contains("-name \(name)"),
        "the bootstrap swap does not preserve \(name), so a cold re-extract destroys it")
    }
  }

  private static func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
