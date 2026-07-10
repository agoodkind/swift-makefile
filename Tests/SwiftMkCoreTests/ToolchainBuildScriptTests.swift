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
    #expect(script.contains(#"printf "%s\n" "--manifest-cache""#))
    #expect(script.contains(#"printf "%s\n" "none""#))
    #expect(!script.contains("-clonedSourcePackagesDirPath"))
    #expect(!script.contains("-disableAutomaticPackageResolution"))
    #expect(!script.contains("--disable-automatic-resolution"))
  }

  @Test
  static func poolBuildScriptHashesResolvedFilesWithManifestFallback() throws {
    let script = try rootFile("scripts/swift-mk-build.sh")
    #expect(script.contains(#"shasum "${manifest_path}""#))
    #expect(script.contains(#"if [[ -f "${resolved_path}" ]]; then"#))
    #expect(script.contains(#"shasum "${resolved_path}""#))

    try withTemporaryDirectory { packageDirectory in
      let manifest = packageDirectory.appendingPathComponent("Package.swift")
      let resolved = packageDirectory.appendingPathComponent("Package.resolved")
      let swiftpmConfiguration = packageDirectory.appendingPathComponent(
        ".swiftpm/configuration",
        isDirectory: true)
      let swiftpmResolved = swiftpmConfiguration.appendingPathComponent("Package.resolved")
      try "manifest-one\n".write(to: manifest, atomically: true, encoding: .utf8)
      try FileManager.default.createDirectory(
        at: swiftpmConfiguration, withIntermediateDirectories: true)

      let manifestOnlyHash = try dependencyHash(for: packageDirectory)
      #expect(isSHA1(manifestOnlyHash))

      try "swiftpm-resolved-one\n".write(to: swiftpmResolved, atomically: true, encoding: .utf8)
      let swiftpmResolvedHash = try dependencyHash(for: packageDirectory)
      #expect(isSHA1(swiftpmResolvedHash))
      #expect(swiftpmResolvedHash != manifestOnlyHash)

      try "swiftpm-resolved-two\n".write(to: swiftpmResolved, atomically: true, encoding: .utf8)
      let changedSwiftpmResolvedHash = try dependencyHash(for: packageDirectory)
      #expect(changedSwiftpmResolvedHash != swiftpmResolvedHash)

      try "resolved-one\n".write(to: resolved, atomically: true, encoding: .utf8)
      let resolvedHash = try dependencyHash(for: packageDirectory)
      #expect(isSHA1(resolvedHash))
      #expect(resolvedHash != changedSwiftpmResolvedHash)

      try "swiftpm-resolved-three\n".write(to: swiftpmResolved, atomically: true, encoding: .utf8)
      let rootResolvedStillWinsHash = try dependencyHash(for: packageDirectory)
      #expect(rootResolvedStillWinsHash == resolvedHash)

      try "resolved-two\n".write(to: resolved, atomically: true, encoding: .utf8)
      let changedResolvedHash = try dependencyHash(for: packageDirectory)
      #expect(changedResolvedHash != resolvedHash)

      try FileManager.default.removeItem(at: swiftpmResolved)
      try FileManager.default.removeItem(at: resolved)
      let fallbackHash = try dependencyHash(for: packageDirectory)
      #expect(fallbackHash == manifestOnlyHash)
    }
  }

  @Test
  static func poolBuildScriptRejectsEmptySwiftPMBinPath() throws {
    let script = try rootFile("scripts/swift-mk-build.sh")
    let validation = #"if [[ "${bin_dir_status}" -ne 0 || -z "${bin_dir}" ]]; then"#
    let binPathAssignment = #"bin_path="${bin_dir}/swift-mk""#
    let validationIndex = script.range(of: validation)?.lowerBound
    let binPathAssignmentIndex = script.range(of: binPathAssignment)?.lowerBound

    #expect(script.contains(validation))
    #expect(script.contains("could not resolve SwiftPM binary output path"))
    #expect(script.contains("swift build --show-bin-path output"))
    #expect(binPathAssignmentIndex != nil)
    if let validationIndex, let binPathAssignmentIndex {
      #expect(validationIndex < binPathAssignmentIndex)
    }
  }

  @Test
  static func poolBuildScriptFailsLoudlyWhenBinPathOutputIsWhitespace() throws {
    let result = try buildScriptResult(
      fakeSwift: """
        #!/usr/bin/env bash
        for arg in "$@"; do
            if [[ "${arg}" == "--show-bin-path" ]]; then
                printf '   \\n\\t\\n'
                exit 0
            fi
        done
        exit 0
        """)

    #expect(result.status == 1)
    #expect(result.stderr.contains("could not resolve SwiftPM binary output path"))
    #expect(result.stderr.contains("swift build --show-bin-path produced no output"))
  }

  @Test
  static func poolBuildScriptReportsFailedBinPathCommandOutput() throws {
    let result = try buildScriptResult(
      fakeSwift: """
        #!/usr/bin/env bash
        for arg in "$@"; do
            if [[ "${arg}" == "--show-bin-path" ]]; then
                printf 'resolver exploded\\n' >&2
                exit 42
            fi
        done
        exit 0
        """)

    #expect(result.status == 1)
    #expect(result.stderr.contains("could not resolve SwiftPM binary output path"))
    #expect(result.stderr.contains("swift build --show-bin-path output"))
    #expect(result.stderr.contains("resolver exploded"))
  }

  @Test
  static func setupBuildEnvConfiguresPoolCacheByMountPresence() throws {
    let action = try rootFile(".github/actions/setup-build-env/action.yml")

    #expect(!action.contains("if: runner.environment == 'self-hosted'"))
    #expect(action.contains(#"if [[ ! -d "${POOL_CACHE_ROOT}" ]]; then"#))
    #expect(action.contains("SWIFT_MK_POOL_LOCAL_CACHE"))
    #expect(!action.contains("SWIFT_MK_MODULE_CACHE=%s"))
  }

  @Test
  static func setupBuildEnvDependencyHashIncludesConsumerManifests() throws {
    let action = try rootFile(".github/actions/setup-build-env/action.yml")
    let expression = try dependencyHashExpression(in: action)

    #expect(expression.contains("'**/Package.swift'"))
    #expect(expression.contains("'**/Package.resolved'"))
    #expect(expression.contains("'**/Project.swift'"))
    #expect(expression.contains("'**/Workspace.swift'"))
    #expect(expression.contains("'**/Tuist.swift'"))
    #expect(expression.contains("'**/project.yml'"))
    #expect(expression.contains("'**/*.xcodeproj/project.pbxproj'"))
    #expect(expression.contains("'**/*.xcworkspace/contents.xcworkspacedata'"))
    #expect(expression.contains("'**/*.xcworkspace/xcshareddata/swiftpm/Package.resolved'"))
    #expect(
      expression.contains(
        "'**/*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'"))
  }

  @Test
  static func setupBuildEnvDependencyHashHasStableNonEmptyFallback() throws {
    let action = try rootFile(".github/actions/setup-build-env/action.yml")

    #expect(!action.contains(#"DEPENDENCY_HASH="no-deps""#))
    #expect(action.contains("dependency_hash_files"))
    #expect(action.contains("git rev-parse HEAD"))
    #expect(action.contains("GITHUB_SHA"))
    #expect(action.contains("*.xcodeproj/project.pbxproj"))
    #expect(action.contains("xcshareddata/swiftpm/Package.resolved"))
  }

  private static func rootFile(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
  }

  private static func dependencyHashExpression(in action: String) throws -> String {
    let lines = action.split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines
    where line.contains("DEPENDENCY_HASH: ${{ hashFiles(") {
      return String(line)
    }
    throw ScriptFailure(message: "missing DEPENDENCY_HASH hashFiles expression")
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

  private static func buildScriptResult(fakeSwift: String) throws -> Shell.Result {
    try withTemporaryDirectory { directory in
      let packageDirectory = directory.appendingPathComponent("package", isDirectory: true)
      let fakeBinDirectory = directory.appendingPathComponent("bin", isDirectory: true)
      let outputPath = directory.appendingPathComponent("out/swift-mk").path
      try FileManager.default.createDirectory(
        at: packageDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: fakeBinDirectory, withIntermediateDirectories: true)
      try "manifest\n".write(
        to: packageDirectory.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8)
      let fakeSwiftPath = fakeBinDirectory.appendingPathComponent("swift")
      try fakeSwift.write(to: fakeSwiftPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: fakeSwiftPath.path)

      let scriptPath = repoRoot().appendingPathComponent("scripts/swift-mk-build.sh").path
      // Pin the subprocess to the package directory. Shell.run inherits the
      // test process's global working directory, which a parallel test's
      // temporary-directory cleanup can remove, so bash would otherwise fail at
      // startup with "getcwd: cannot access parent directories".
      let command =
        #"cd "${SWIFT_MK_BUILD_REPO}"; source "${SCRIPT_PATH}" path >/dev/null; swift_mk_build_from_repo"#
      let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
      return Shell.run(
        "/bin/bash",
        ["-c", command],
        environment: [
          "PATH": "\(fakeBinDirectory.path):\(existingPath)",
          "SCRIPT_PATH": scriptPath,
          "SWIFT_MK_BIN": outputPath,
          "SWIFT_MK_BUILD_REPO": packageDirectory.path,
        ])
    }
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

  private static func withTemporaryDirectory<Result>(_ run: (URL) throws -> Result) throws
    -> Result
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-build-script-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      removeTemporaryDirectory(directory)
    }
    return try run(directory)
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
