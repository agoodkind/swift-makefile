//
//  BootstrapFetchTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BootstrapFetchTests

enum BootstrapFetchTests {}

/// The engine tree the test server serves. It carries every asset the helper
/// must provision, so a cold run has a complete source.
func engineFiles() -> [String: String] {
  [
    "swift.mk": "# swift.mk v1\n",
    "Package.swift": "// swift-tools-version: 6.0\n",
    "scripts/swift-mk-build.sh": "#!/usr/bin/env bash\nexit 0\n",
    "scripts/swift-mk-fetch-one.sh": "#!/usr/bin/env bash\nexit 0\n",
    "scripts/swift-mk-sync.sh": "#!/usr/bin/env bash\nexit 0\n",
    "scripts/swift-mk-bootstrap.sh": "#!/usr/bin/env bash\nexit 0\n",
    ".swiftlint.yml": "# swiftlint v1\n",
    ".swift-format": "{}\n",
    ".periphery.yml": "# periphery v1\n",
    "osv-scanner.toml": "# osv v1\n",
    "mise.toml": "# mise v1\n",
  ]
}

func temporaryConsumer() throws -> String {
  let path = NSTemporaryDirectory() + "swift-mk-consumer-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

func makePath(_ directory: String, _ relative: String) -> String {
  (directory as NSString).appendingPathComponent(".make/" + relative)
}

func writeMakeFile(_ directory: String, _ relative: String, _ body: String) throws {
  let path = makePath(directory, relative)
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try body.write(toFile: path, atomically: true, encoding: .utf8)
}

func readMakeFile(_ directory: String, _ relative: String) -> String? {
  try? String(contentsOfFile: makePath(directory, relative), encoding: .utf8)
}

/// Runs the helper with the working directory at `directory` and an environment
/// that never inherits a real CI context.
func runHelper(directory: String, environment: [String: String]) -> (
  stdout: String, stderr: String, status: Int32
) {
  let helper = repositoryRoot() + "/scripts/swift-mk-bootstrap.sh"
  var merged: [String: String] = [
    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
    "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "",
    "SWIFT_MK_API_REPO": "agoodkind/swift-makefile",
    "SWIFT_MK_API_REF": "main",
    "SWIFT_MK_DEV_DIR": "",
    "SWIFT_MK_MODULES": "",
    "GITHUB_ACTIONS": "",
    "GITHUB_RUN_ID": "",
  ]
  for (key, value) in environment {
    merged[key] = value
  }

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/bash")
  process.arguments = [helper]
  process.currentDirectoryURL = URL(fileURLWithPath: directory)
  process.environment = merged
  let outPipe = Pipe()
  let errPipe = Pipe()
  process.standardOutput = outPipe
  process.standardError = errPipe
  try? process.run()
  let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
  let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (
    String(decoding: outData, as: UTF8.self),
    String(decoding: errData, as: UTF8.self),
    process.terminationStatus
  )
}

func repositoryRoot() -> String {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .path
}

@Test
func helperColdProvisionWritesEveryAsset() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status == 0, "helper failed: \(result.stderr)")

  #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v1\n")
  #expect(readMakeFile(directory, "Package.swift") != nil)
  #expect(readMakeFile(directory, "scripts/swift-mk-build.sh") != nil)
  #expect(server.requests().count == 1)
}

@Test
func helperLeavesSnapshotIntactWhenUpstreamIsUnreachable() throws {
  let directory = try temporaryConsumer()
  try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
  try writeMakeFile(directory, "Package.swift", "// warm\n")
  try writeMakeFile(directory, "scripts/swift-mk-build.sh", "#!/usr/bin/env bash\nexit 0\n")

  // A port nothing listens on, so every request fails at connect.
  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": "http://127.0.0.1:9"])
  #expect(result.status != 0)

  // The point of the task: a failed fetch must not remove what was there.
  #expect(readMakeFile(directory, "swift.mk") == "# warm swift.mk\n")
  #expect(readMakeFile(directory, "Package.swift") == "// warm\n")
}
