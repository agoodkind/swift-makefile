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
    let engineFiles = [orphanSource, enginePackage, engineModule]
    let generatedFiles = [
      buildLock, logsEntry, binary, binaryKey, devLink, marker, snapshotLog,
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

  private static func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
