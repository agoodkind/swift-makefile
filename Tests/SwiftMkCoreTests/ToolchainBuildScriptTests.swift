//
//  ToolchainBuildScriptTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-07.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ToolchainBuildScriptTests

enum ToolchainBuildScriptTests {
  @Test
  static func poolBuildScriptUsesOnlySwiftPMCacheFlags() throws {
    let script = try rootFile("scripts/swift-mk-build.sh")

    #expect(script.contains(#"printf "%s\n" "--cache-path""#))
    #expect(!script.contains("-clonedSourcePackagesDirPath"))
    #expect(!script.contains("-disableAutomaticPackageResolution"))
    #expect(!script.contains("--disable-automatic-resolution"))
  }

  @Test
  static func poolBuildScriptHashesResolvedFileOnlyWhenPresent() throws {
    try withTemporaryDirectory { packageDirectory in
      let manifest = packageDirectory.appendingPathComponent("Package.swift")
      let resolved = packageDirectory.appendingPathComponent("Package.resolved")
      try "manifest-one\n".write(to: manifest, atomically: true, encoding: .utf8)

      let manifestOnlyHash = try dependencyHash(for: packageDirectory)
      #expect(isSHA1(manifestOnlyHash))

      try "resolved-one\n".write(to: resolved, atomically: true, encoding: .utf8)
      let resolvedHash = try dependencyHash(for: packageDirectory)
      #expect(isSHA1(resolvedHash))
      #expect(resolvedHash != manifestOnlyHash)

      try "resolved-two\n".write(to: resolved, atomically: true, encoding: .utf8)
      let changedResolvedHash = try dependencyHash(for: packageDirectory)
      #expect(changedResolvedHash != resolvedHash)

      try FileManager.default.removeItem(at: resolved)
      let fallbackHash = try dependencyHash(for: packageDirectory)
      #expect(fallbackHash == manifestOnlyHash)
    }
  }

  @Test
  static func poolBuildScriptRejectsEmptySwiftPMBinPath() throws {
    let script = try rootFile("scripts/swift-mk-build.sh")
    let validation = #"if [[ -z "${bin_dir}" ]]; then"#
    let binPathAssignment = #"bin_path="${bin_dir}/swift-mk""#
    let validationIndex = script.range(of: validation)?.lowerBound
    let binPathAssignmentIndex = script.range(of: binPathAssignment)?.lowerBound

    #expect(script.contains(validation))
    #expect(script.contains("could not resolve SwiftPM binary output path"))
    #expect(binPathAssignmentIndex != nil)
    if let validationIndex, let binPathAssignmentIndex {
      #expect(validationIndex < binPathAssignmentIndex)
    }
  }

  @Test
  static func setupBuildEnvConfiguresPoolCacheByMountPresence() throws {
    let action = try rootFile(".github/actions/setup-build-env/action.yml")

    #expect(!action.contains("if: runner.environment == 'self-hosted'"))
    #expect(action.contains(#"if [[ ! -d "${POOL_CACHE_ROOT}" ]]; then"#))
  }

  private static func rootFile(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
  }

  private static func dependencyHash(for packageDirectory: URL) throws -> String {
    let scriptPath = repoRoot().appendingPathComponent("scripts/swift-mk-build.sh").path
    let command =
      #"source "${SCRIPT_PATH}" path >/dev/null; "#
      + #"swift_mk_dependency_hash "${PACKAGE_PATH}""#
    let result = Shell.run(
      "/bin/bash",
      ["-c", command],
      environment: [
        "SCRIPT_PATH": scriptPath,
        "PACKAGE_PATH": packageDirectory.path,
      ])
    guard result.status == 0 else {
      throw ScriptFailure(message: result.stderr)
    }
    let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.count == 1, let line = lines.first else {
      throw ScriptFailure(message: "unexpected dependency hash output: \(result.stdout)")
    }
    return String(line)
  }

  private static func isSHA1(_ value: String) -> Bool {
    value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
  }

  private static func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func withTemporaryDirectory(_ run: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-build-script-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      removeTemporaryDirectory(directory)
    }
    try run(directory)
  }

  private static func removeTemporaryDirectory(_ directory: URL) {
    let removalResult = Result {
      try FileManager.default.removeItem(at: directory)
    }
    if case .failure(let error) = removalResult {
      Issue.record("could not remove temporary directory \(directory.path): \(error)")
    }
  }
}

// MARK: - ScriptFailure

private struct ScriptFailure: Error, CustomStringConvertible {
  let message: String

  var description: String {
    message
  }
}
