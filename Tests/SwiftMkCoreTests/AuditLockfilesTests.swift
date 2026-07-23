//
//  AuditLockfilesTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - AuditLockfilesTests

enum AuditLockfilesTests {}

@Test
func scannerArgumentsStripRecursiveAndPassLockfiles() {
  let args = AuditLockfiles.scannerArguments(
    configured: ["--recursive", "--allow-no-lockfiles", "--config", "cfg.toml"],
    lockfiles: ["Package.resolved", "Apps/Foo/Package.resolved"])
  #expect(
    args == [
      "scan", "source",
      "--allow-no-lockfiles", "--config", "cfg.toml",
      "-L", "Package.resolved",
      "-L", "Apps/Foo/Package.resolved",
    ])
}

@Test
func discoverUsesGitEffectiveIgnoreForGlobalExcludes() throws {
  // A lockfile under a path ignored only via core.excludesFile must stay out of
  // the audit set, matching git ls-files --exclude-standard rather than osv's
  // recursive walk (which misses the global excludes file).
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-audit-lockfiles-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer {
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      Output.warning("cleanup failed: \(error.localizedDescription)")
    }
  }

  let excludesFile = directory.appendingPathComponent("excludes")
  try ".claude/\n".write(to: excludesFile, atomically: true, encoding: .utf8)

  let initResult = Shell.run("git", ["-C", directory.path, "init"])
  #expect(initResult.status == 0)
  let configResult = Shell.run(
    "git",
    ["-C", directory.path, "config", "core.excludesFile", excludesFile.path])
  #expect(configResult.status == 0)

  try "{ \"pins\" : [], \"version\" : 2 }\n".write(
    to: directory.appendingPathComponent("Package.resolved"),
    atomically: true,
    encoding: .utf8)
  let ignored = directory.appendingPathComponent(
    ".claude/worktrees/x/Package.resolved")
  try FileManager.default.createDirectory(
    at: ignored.deletingLastPathComponent(), withIntermediateDirectories: true)
  try "{ \"pins\" : [], \"version\" : 2 }\n".write(
    to: ignored, atomically: true, encoding: .utf8)

  let discovered = Set(AuditLockfiles.discover(root: directory.path))
  #expect(discovered == ["Package.resolved"])
}
