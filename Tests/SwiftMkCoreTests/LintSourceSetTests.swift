//
//  LintSourceSetTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - LintSourceSetTests

/// The hard gate's source discovery: tracked and untracked `.swift` files are
/// included, git-ignored build output is excluded, nested manifests and tool
/// scripts are included, and caller-supplied narrowers cannot shrink the set.
@Suite(.serialized)
enum LintSourceSetTests {
  @Test
  static func includesTrackedUntrackedAndManifestsExcludesIgnored() throws {
    try withTemporaryGitRepo { root in
      let resolved = Set(
        LintSourceSet.resolve(context: PathContext(pwd: root + "/", cwd: root + "/")))
      #expect(resolved.contains("Sources/Tracked.swift"))
      #expect(resolved.contains("Untracked.swift"))
      #expect(resolved.contains("Package.swift"))
      #expect(resolved.contains("Nested/Package.swift"))
      #expect(resolved.contains("Tools/Helper.swift"))
      #expect(!resolved.contains("build/Generated.swift"))
    }
  }

  @Test
  static func ignoresCallerNarrowers() throws {
    // The hard gate must not be narrowable: SWIFTLINT_TARGETS and LINT_FILES that
    // point elsewhere do not change the discovered set.
    try withTemporaryGitRepo { root in
      let saved = Environment.snapshot(["SWIFTLINT_TARGETS", "LINT_FILES", "SWIFT_FORMAT_TARGETS"])
      defer { saved.restore() }
      setenv("SWIFTLINT_TARGETS", "/nonexistent", 1)
      setenv("LINT_FILES", "Untracked.swift", 1)
      setenv("SWIFT_FORMAT_TARGETS", "/nonexistent", 1)
      let resolved = Set(
        LintSourceSet.resolve(context: PathContext(pwd: root + "/", cwd: root + "/")))
      #expect(resolved.contains("Sources/Tracked.swift"))
      #expect(resolved.contains("Untracked.swift"))
      #expect(resolved.contains("Package.swift"))
    }
  }

  // MARK: helpers

  private static func withTemporaryGitRepo(_ body: (String) throws -> Void) throws {
    try TestGlobalLock.withLock {
      try withTemporaryGitRepoLocked(body)
    }
  }

  private static func withTemporaryGitRepoLocked(_ body: (String) throws -> Void) throws {
    let manager = FileManager.default
    let root = NSTemporaryDirectory() + "swiftmk-srcset-" + UUID().uuidString
    try manager.createDirectory(atPath: root + "/Sources", withIntermediateDirectories: true)
    try manager.createDirectory(atPath: root + "/Nested", withIntermediateDirectories: true)
    try manager.createDirectory(atPath: root + "/Tools", withIntermediateDirectories: true)
    try manager.createDirectory(atPath: root + "/build", withIntermediateDirectories: true)
    try "let tracked = 1\n".write(
      toFile: root + "/Sources/Tracked.swift", atomically: true, encoding: .utf8)
    try "let untracked = 1\n".write(
      toFile: root + "/Untracked.swift", atomically: true, encoding: .utf8)
    try "// manifest\n".write(
      toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
    try "// nested manifest\n".write(
      toFile: root + "/Nested/Package.swift", atomically: true, encoding: .utf8)
    try "let helper = 1\n".write(
      toFile: root + "/Tools/Helper.swift", atomically: true, encoding: .utf8)
    try "let generated = 1\n".write(
      toFile: root + "/build/Generated.swift", atomically: true, encoding: .utf8)
    try "build/\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)

    let savedCwd = manager.currentDirectoryPath
    defer {
      manager.changeCurrentDirectoryPath(savedCwd)
      removeTemporary(root)
    }
    _ = Shell.run("git", ["-C", root, "init", "-q"])
    // Track only Sources/Tracked.swift and the manifests; leave Untracked.swift and
    // build/Generated.swift untracked, the latter covered by .gitignore.
    _ = Shell.run(
      "git",
      [
        "-C", root, "add", "Sources/Tracked.swift", "Package.swift",
        "Nested/Package.swift", "Tools/Helper.swift",
      ])
    manager.changeCurrentDirectoryPath(root)
    try body(root)
  }
}
