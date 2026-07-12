//
//  ResolveHarness.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-11.
//  Copyright © 2026, all rights reserved.
//

import Foundation

@testable import SwiftMkCore

// MARK: - ResolveHarness

/// A temporary package plus a fake `swift` for exercising `swift_mk_resolve_bin`
/// across repeated calls, so a test can watch the content key drive a reuse or a
/// rebuild without a real toolchain. The fake records each build, answers
/// `--show-bin-path` with a fixed product directory, and reports a
/// caller-controlled `--version` string that feeds the content key's toolchain id.
struct ResolveHarness {
  let packageDirectory: URL
  let sourceFile: URL
  let outputPath: String
  let fakeSwiftDirectory: URL
  let fakeBinDirectory: URL
  let toolchainIDFile: URL
  let buildCountFile: URL

  private static let fakeSwift = #"""
    #!/usr/bin/env bash
    mkdir -p "${FAKE_BIN_DIR}"
    for arg in "$@"; do
        case "${arg}" in
            --show-bin-path) printf '%s\n' "${FAKE_BIN_DIR}"; exit 0 ;;
            --version) cat "${FAKE_TOOLCHAIN_ID_FILE}" 2>/dev/null || true; exit 0 ;;
            --product) is_build=1 ;;
        esac
    done
    if [[ "${is_build:-}" == "1" ]]; then
        printf 'x\n' >> "${FAKE_BUILD_COUNT_FILE}"
        cp /bin/echo "${FAKE_BIN_DIR}/swift-mk"
        chmod +x "${FAKE_BIN_DIR}/swift-mk"
    fi
    exit 0
    """#

  static func make(in directory: URL) throws -> ResolveHarness {
    let packageURL = directory.appendingPathComponent("package", isDirectory: true)
    let sourcesURL = packageURL.appendingPathComponent("Sources", isDirectory: true)
    let fakeSwiftURL = directory.appendingPathComponent("fakebin", isDirectory: true)
    let harness = ResolveHarness(
      packageDirectory: packageURL,
      sourceFile: sourcesURL.appendingPathComponent("main.swift"),
      outputPath: directory.appendingPathComponent("out/swift-mk").path,
      fakeSwiftDirectory: fakeSwiftURL,
      fakeBinDirectory: directory.appendingPathComponent("bin", isDirectory: true),
      toolchainIDFile: directory.appendingPathComponent("toolchain-id"),
      buildCountFile: directory.appendingPathComponent("build-count"))

    for created in [sourcesURL, harness.fakeBinDirectory, fakeSwiftURL] {
      try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    }
    try "manifest\n".write(
      to: packageURL.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8)
    try harness.writeSource("source-one\n")
    try harness.writeToolchainID("toolchain-one\n")

    let fakeSwiftPath = fakeSwiftURL.appendingPathComponent("swift")
    try fakeSwift.write(to: fakeSwiftPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fakeSwiftPath.path)
    return harness
  }

  func resolve() -> Shell.Result {
    let scriptPath = ResolveHarness.repoRoot()
      .appendingPathComponent("scripts/swift-mk-build.sh").path
    let command =
      #"cd "${SWIFT_MK_BUILD_REPO}"; source "${SCRIPT_PATH}" path >/dev/null; swift_mk_resolve_bin"#
    let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    return Shell.run(
      "/bin/bash",
      ["-c", command],
      environment: [
        "PATH": "\(fakeSwiftDirectory.path):\(existingPath)",
        "SCRIPT_PATH": scriptPath,
        "SWIFT_MK_BIN": outputPath,
        "SWIFT_MK_BUILD_REPO": packageDirectory.path,
        "FAKE_BIN_DIR": fakeBinDirectory.path,
        "FAKE_TOOLCHAIN_ID_FILE": toolchainIDFile.path,
        "FAKE_BUILD_COUNT_FILE": buildCountFile.path,
        // The CI job exports SWIFT_MK_BIN_VERIFIED=1 from setup-build-env, and the child
        // inherits the ambient environment, so pin it empty here. Otherwise
        // swift_mk_resolve_bin takes the verified-binary trust path and never rechecks
        // the content key, which is exactly the reuse-versus-rebuild logic under test.
        "SWIFT_MK_BIN_VERIFIED": "",
      ])
  }

  func buildCount() throws -> Int {
    guard FileManager.default.fileExists(atPath: buildCountFile.path) else {
      return 0
    }
    let contents = try String(contentsOf: buildCountFile, encoding: .utf8)
    return contents.split(separator: "\n", omittingEmptySubsequences: true).count
  }

  func binaryModificationDate() throws -> Date {
    let attributes = try FileManager.default.attributesOfItem(atPath: outputPath)
    return (attributes[.modificationDate] as? Date) ?? Date.distantPast
  }

  func writeSource(_ contents: String) throws {
    try contents.write(to: sourceFile, atomically: true, encoding: .utf8)
  }

  func writeToolchainID(_ contents: String) throws {
    try contents.write(to: toolchainIDFile, atomically: true, encoding: .utf8)
  }

  private static func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
