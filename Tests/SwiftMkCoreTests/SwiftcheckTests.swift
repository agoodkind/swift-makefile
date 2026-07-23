//
//  SwiftcheckTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - SwiftcheckTests

enum SwiftcheckTests {}

// MARK: - OutputNeedsBuildFixture

private struct OutputNeedsBuildFixture {
  let binaryPath: String
  let repoPath: String
  let sourcesDirectory: URL
}

private func withOutputNeedsBuildFixture(
  prefix: String,
  _ body: (OutputNeedsBuildFixture) throws -> Void
) throws {
  let savedFlags = Environment.snapshot(["SWIFTCHECK_EXTRA_FLAGS"])
  defer { savedFlags.restore() }
  setenv("SWIFTCHECK_EXTRA_FLAGS", "", 1)

  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-swiftcheck-\(prefix)-\(UUID().uuidString)",
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

  let binaryPath = directory.appendingPathComponent("swiftcheck-extra").path
  let repo = directory.appendingPathComponent("repo", isDirectory: true)
  let sourcesDirectory = repo.appendingPathComponent("Sources", isDirectory: true)
  try FileManager.default.createDirectory(
    at: sourcesDirectory, withIntermediateDirectories: true)

  let script = "#!/bin/sh\necho 'Name: missing_boundary_log'\n"
  try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
  try body(
    OutputNeedsBuildFixture(
      binaryPath: binaryPath,
      repoPath: repo.path,
      sourcesDirectory: sourcesDirectory))
}

@Test
func parsesRawFindingsBeforeApplyingExcludes() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-swiftcheck-\(UUID().uuidString)",
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

  let rawPath = directory.appendingPathComponent("swiftcheck.raw.out").path
  let rawOutput =
    "Sources/SwiftMkCore/Toolchain.swift:42:5: silent_try: handle throwing calls explicitly\n"
  try rawOutput.write(toFile: rawPath, atomically: true, encoding: .utf8)
  let context = PathContext(pwd: directory.path + "/", cwd: directory.path + "/")

  let parsedAll = Swiftcheck.parseFindings(rawPath: rawPath, context: context)
  let parsedFindings = Swiftcheck.structuredFindings(
    rawPath: rawPath,
    exclude: "Sources/SwiftMkCore/Toolchain.swift",
    context: context
  )

  #expect(parsedAll.count == 1)
  #expect(parsedFindings.isEmpty)
  #expect(!Swiftcheck.isToolFailure(status: 1, parsedAll: parsedAll))
  #expect(Swiftcheck.isToolFailure(status: 1, parsedAll: []))
}

@Test
func outputNeedsBuildWhenSourcesAreNewerThanBinary() throws {
  // A present analyzer binary must still rebuild when its sources are newer. The
  // gate previously skipped resolveBin whenever selectedBin was already set, so a
  // stale .make/swiftcheck-extra kept enforcing old rule semantics.
  try TestGlobalLock.withLock {
    try withOutputNeedsBuildFixture(prefix: "stale") { fixture in
      let sourcePath = fixture.sourcesDirectory.appendingPathComponent("Probe.swift").path
      try "let x = 1\n".write(toFile: sourcePath, atomically: true, encoding: .utf8)

      let initial = Swiftcheck.buildInputFingerprint(repo: fixture.repoPath)
      try initial.write(
        toFile: Swiftcheck.fingerprintPath(forOutput: fixture.binaryPath),
        atomically: true,
        encoding: .utf8)
      #expect(
        !Swiftcheck.outputNeedsBuild(output: fixture.binaryPath, repo: fixture.repoPath))

      try "let x = 22\n".write(toFile: sourcePath, atomically: true, encoding: .utf8)
      #expect(
        Swiftcheck.outputNeedsBuild(output: fixture.binaryPath, repo: fixture.repoPath))
    }
  }
}

@Test
func outputNeedsBuildWhenPackageSwiftChanges() throws {
  try TestGlobalLock.withLock {
    try withOutputNeedsBuildFixture(prefix: "package") { fixture in
      let repo = URL(fileURLWithPath: fixture.repoPath, isDirectory: true)
      let packagePath = repo.appendingPathComponent("Package.swift").path
      let sourcePath = fixture.sourcesDirectory.appendingPathComponent("Probe.swift").path
      try "// swift-tools-version: 6.0\n".write(
        toFile: packagePath, atomically: true, encoding: .utf8)
      try "let x = 1\n".write(toFile: sourcePath, atomically: true, encoding: .utf8)

      let initial = Swiftcheck.buildInputFingerprint(repo: fixture.repoPath)
      try initial.write(
        toFile: Swiftcheck.fingerprintPath(forOutput: fixture.binaryPath),
        atomically: true,
        encoding: .utf8)
      #expect(
        !Swiftcheck.outputNeedsBuild(output: fixture.binaryPath, repo: fixture.repoPath))

      try "// swift-tools-version: 6.0\n// touched\n".write(
        toFile: packagePath, atomically: true, encoding: .utf8)
      #expect(
        Swiftcheck.outputNeedsBuild(output: fixture.binaryPath, repo: fixture.repoPath))
    }
  }
}

@Test
func outputNeedsBuildWhenSourceIsDeleted() throws {
  try TestGlobalLock.withLock {
    try withOutputNeedsBuildFixture(prefix: "delete") { fixture in
      let keepPath = fixture.sourcesDirectory.appendingPathComponent("Keep.swift").path
      let dropPath = fixture.sourcesDirectory.appendingPathComponent("Drop.swift").path
      try "let keep = 1\n".write(toFile: keepPath, atomically: true, encoding: .utf8)
      try "let drop = 1\n".write(toFile: dropPath, atomically: true, encoding: .utf8)

      let initial = Swiftcheck.buildInputFingerprint(repo: fixture.repoPath)
      try initial.write(
        toFile: Swiftcheck.fingerprintPath(forOutput: fixture.binaryPath),
        atomically: true,
        encoding: .utf8)
      #expect(
        !Swiftcheck.outputNeedsBuild(output: fixture.binaryPath, repo: fixture.repoPath))

      try FileManager.default.removeItem(atPath: dropPath)
      #expect(
        Swiftcheck.outputNeedsBuild(output: fixture.binaryPath, repo: fixture.repoPath))
    }
  }
}

@Test
func preparedBinRequiresSuccessfulResolve() {
  // preparedBin must refuse a missing override instead of falling through to a
  // stale on-disk binary. The previous gate path ignored resolveBin's result when
  // selectedBin was already non-nil.
  let previous = ProcessInfo.processInfo.environment["SWIFTCHECK_EXTRA_BIN"]
  setenv("SWIFTCHECK_EXTRA_BIN", "/tmp/swift-mk-missing-swiftcheck-extra", 1)
  defer {
    if let previous {
      setenv("SWIFTCHECK_EXTRA_BIN", previous, 1)
    } else {
      unsetenv("SWIFTCHECK_EXTRA_BIN")
    }
  }

  #expect(Swiftcheck.preparedBin() == nil)
}
