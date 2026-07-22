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
  static func poolBuildScriptHashesResolvedFilesWithManifestFallback() throws {
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
  static func poolBuildScriptCopiesRunnableAdHocSignedBinary() throws {
    // A copied arm64 binary can carry a stale linker signature and a provenance
    // xattr that make the kernel kill it on launch. The script clears the xattrs
    // and re-signs ad-hoc after the cp; this proves the copied output actually
    // launches, carries an ad-hoc signature, and has its provenance xattr cleared,
    // not just that the script text mentions xattr/codesign. The fixture seeds a
    // com.apple.quarantine xattr on the compiled binary, which macOS `cp` carries
    // to the output, so a regression that drops `xattr -c` leaves the xattr on the
    // output and fails the residual-xattr assertion below. The fixture is a freshly
    // compiled binary, not a copy of a system binary like /bin/echo: re-signing a
    // copied system binary fails platform binary validation and is killed on launch
    // on a clean macOS runner, which is a property of the fixture, not of the script
    // under test. Skips where a required tool is unavailable.
    guard
      commandAvailable("xattr"), commandAvailable("codesign"), commandAvailable("clang")
    else {
      return
    }

    try runBuildScript(
      fakeSwift: """
        #!/usr/bin/env bash
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        bin_dir="${script_dir}/show-bin-path-output"
        mkdir -p "${bin_dir}"
        for arg in "$@"; do
            if [[ "${arg}" == "--show-bin-path" ]]; then
                printf "%s\\n" "${bin_dir}"
                exit 0
            fi
        done
        printf 'int main(void){return 0;}\\n' | clang -x c - -o "${bin_dir}/swift-mk"
        chmod +x "${bin_dir}/swift-mk"
        xattr -w com.apple.quarantine '0081;00000000;SwiftMkTest;' "${bin_dir}/swift-mk"
        exit 0
        """
    ) { result, outputPath in
      #expect(result.status == 0)
      #expect(FileManager.default.isExecutableFile(atPath: outputPath))

      let launch = Shell.run(outputPath)
      #expect(launch.status == 0)

      let signature = Shell.run("/usr/bin/codesign", ["-dvv", outputPath])
      #expect(signature.combined.contains("Signature=adhoc"))

      // The seeded provenance xattr must be gone from the output, proving the
      // script's `xattr -c` actually ran rather than the launch merely succeeding.
      let residualXattr = Shell.run("/usr/bin/xattr", ["-l", outputPath])
      #expect(
        !residualXattr.combined.contains("com.apple.quarantine"),
        "provenance xattr should be cleared from the output: \(residualXattr.combined)")
    }
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
    try runBuildScript(fakeSwift: fakeSwift) { result, _ in
      result
    }
  }

  /// Run `swift_mk_build_from_repo` against a fake `swift`, then invoke `body`
  /// with the script result and the output binary path while the temporary
  /// directory still exists, so a caller can inspect the copied binary before
  /// cleanup removes it.
  private static func runBuildScript<Value>(
    fakeSwift: String,
    _ body: (Shell.Result, String) throws -> Value
  ) throws -> Value {
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
      let result = Shell.run(
        "/bin/bash",
        ["-c", command],
        environment: [
          "PATH": "\(fakeBinDirectory.path):\(existingPath)",
          "SCRIPT_PATH": scriptPath,
          "SWIFT_MK_BIN": outputPath,
          "SWIFT_MK_BUILD_REPO": packageDirectory.path,
        ])
      return try body(result, outputPath)
    }
  }

  private static func commandAvailable(_ command: String) -> Bool {
    Shell.run("/bin/sh", ["-c", "command -v \(command)"]).status == 0
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

// MARK: - Toolchain reuse invariants

extension ToolchainBuildScriptTests {
  @Test
  static func toolchainContentKeyDrivesReuse() throws {
    try withTemporaryDirectory { directory in
      let harness = try ResolveHarness.make(in: directory)

      // The first resolve builds the binary and records its content key.
      #expect(harness.resolve().status == 0)
      #expect(try harness.buildCount() == 1)
      #expect(FileManager.default.isExecutableFile(atPath: harness.outputPath))
      let firstModification = try harness.binaryModificationDate()

      // An unchanged source and toolchain reuse the binary: no rebuild, mtime unchanged.
      #expect(harness.resolve().status == 0)
      #expect(try harness.buildCount() == 1)
      #expect(try harness.binaryModificationDate() == firstModification)

      // A changed source triggers a rebuild.
      try harness.writeSource("source-two\n")
      #expect(harness.resolve().status == 0)
      #expect(try harness.buildCount() == 2)

      // A changed toolchain id triggers a rebuild even with the source unchanged.
      try harness.writeToolchainID("toolchain-two\n")
      #expect(harness.resolve().status == 0)
      #expect(try harness.buildCount() == 3)

      // A content-preserving rename triggers a rebuild: the key folds each input's
      // package-relative path, so moving a source to a new name changes the key even
      // though its bytes are identical, and the stale binary is not reused.
      let renamed = harness.sourceFile.deletingLastPathComponent()
        .appendingPathComponent("Renamed.swift")
      try FileManager.default.moveItem(at: harness.sourceFile, to: renamed)
      #expect(harness.resolve().status == 0)
      #expect(try harness.buildCount() == 4)
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
