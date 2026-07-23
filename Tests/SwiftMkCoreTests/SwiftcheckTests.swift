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
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-swiftcheck-stale-\(UUID().uuidString)",
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
  let repoPath = directory.appendingPathComponent("repo", isDirectory: true).path
  let sourcePath = directory.appendingPathComponent("repo/Sources/Probe.swift").path
  try FileManager.default.createDirectory(
    atPath: (sourcePath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true)

  let script = "#!/bin/sh\necho 'Name: missing_boundary_log'\n"
  try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
  try "let x = 1\n".write(toFile: sourcePath, atomically: true, encoding: .utf8)

  let initial = Swiftcheck.buildInputFingerprint(repo: repoPath)
  try initial.write(
    toFile: Swiftcheck.fingerprintPath(forOutput: binaryPath), atomically: true, encoding: .utf8)
  #expect(!Swiftcheck.outputNeedsBuild(output: binaryPath, repo: repoPath))

  try "let x = 22\n".write(toFile: sourcePath, atomically: true, encoding: .utf8)
  #expect(Swiftcheck.outputNeedsBuild(output: binaryPath, repo: repoPath))
}

@Test
func outputNeedsBuildWhenPackageSwiftChanges() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-swiftcheck-package-\(UUID().uuidString)",
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
  let repoPath = directory.appendingPathComponent("repo", isDirectory: true).path
  let packagePath = directory.appendingPathComponent("repo/Package.swift").path
  let sourcePath = directory.appendingPathComponent("repo/Sources/Probe.swift").path
  try FileManager.default.createDirectory(
    atPath: (sourcePath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true)

  let script = "#!/bin/sh\necho 'Name: missing_boundary_log'\n"
  try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
  try "// swift-tools-version: 6.0\n".write(toFile: packagePath, atomically: true, encoding: .utf8)
  try "let x = 1\n".write(toFile: sourcePath, atomically: true, encoding: .utf8)

  let initial = Swiftcheck.buildInputFingerprint(repo: repoPath)
  try initial.write(
    toFile: Swiftcheck.fingerprintPath(forOutput: binaryPath), atomically: true, encoding: .utf8)
  #expect(!Swiftcheck.outputNeedsBuild(output: binaryPath, repo: repoPath))

  try "// swift-tools-version: 6.0\n// touched\n".write(
    toFile: packagePath, atomically: true, encoding: .utf8)
  #expect(Swiftcheck.outputNeedsBuild(output: binaryPath, repo: repoPath))
}

@Test
func outputNeedsBuildWhenSourceIsDeleted() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-swiftcheck-delete-\(UUID().uuidString)",
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
  let repoPath = directory.appendingPathComponent("repo", isDirectory: true).path
  let keepPath = directory.appendingPathComponent("repo/Sources/Keep.swift").path
  let dropPath = directory.appendingPathComponent("repo/Sources/Drop.swift").path
  try FileManager.default.createDirectory(
    atPath: (keepPath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true)

  let script = "#!/bin/sh\necho 'Name: missing_boundary_log'\n"
  try script.write(toFile: binaryPath, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
  try "let keep = 1\n".write(toFile: keepPath, atomically: true, encoding: .utf8)
  try "let drop = 1\n".write(toFile: dropPath, atomically: true, encoding: .utf8)

  let initial = Swiftcheck.buildInputFingerprint(repo: repoPath)
  try initial.write(
    toFile: Swiftcheck.fingerprintPath(forOutput: binaryPath), atomically: true, encoding: .utf8)
  #expect(!Swiftcheck.outputNeedsBuild(output: binaryPath, repo: repoPath))

  try FileManager.default.removeItem(atPath: dropPath)
  #expect(Swiftcheck.outputNeedsBuild(output: binaryPath, repo: repoPath))
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
