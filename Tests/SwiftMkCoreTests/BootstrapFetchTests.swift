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
  let requests = server.requests()
  #expect(requests.count == 1)
  // Proves the helper asked for the configured repo and ref, not just any
  // path the test server happened to answer.
  #expect(requests.first?.path == "/agoodkind/swift-makefile/tar.gz/main")
}

@Test
func helperLeavesSnapshotIntactWhenUpstreamReturnsAnError() throws {
  // A real server that answers with a real HTTP error, not an unreachable
  // port. A helper that merely runs `exit 1`, is missing entirely (exit 127),
  // or has a syntax error would also leave the warm tree untouched, without
  // ever making a request; asserting the request count rules those out and
  // proves the helper actually reached the network and then chose, on a real
  // failure response, not to touch .make.
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  server.forceStatus(500)

  let directory = try temporaryConsumer()
  try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
  try writeMakeFile(directory, "Package.swift", "// warm\n")
  try writeMakeFile(directory, "scripts/swift-mk-build.sh", "#!/usr/bin/env bash\nexit 0\n")

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status != 0)
  #expect(server.requests().count == 1)

  // The point of the task: a failed fetch must not remove what was there.
  #expect(readMakeFile(directory, "swift.mk") == "# warm swift.mk\n")
  #expect(readMakeFile(directory, "Package.swift") == "// warm\n")
}

@Test
func helperRejectsIncompleteSnapshotAndPreservesWarmTree() throws {
  // The server answers 200 with a real tarball that extracts cleanly, but the
  // tarball is missing Package.swift. This is the case the staged-verification
  // design exists for: a fetch that succeeds at the transport level must
  // still be rejected, and rejected before anything under .make is touched.
  var incompleteFiles = engineFiles()
  incompleteFiles.removeValue(forKey: "Package.swift")
  let server = try FetchServer(files: incompleteFiles)
  defer { server.shutdown() }

  let directory = try temporaryConsumer()
  try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
  try writeMakeFile(directory, "Package.swift", "// warm\n")
  try writeMakeFile(directory, "scripts/swift-mk-build.sh", "#!/usr/bin/env bash\nexit 0\n")

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status != 0)
  #expect(server.requests().count == 1)

  #expect(readMakeFile(directory, "swift.mk") == "# warm swift.mk\n")
  #expect(readMakeFile(directory, "Package.swift") == "// warm\n")
}

@Test
func helperSwapFailureLeavesWarmTreeIntactForLaterSkipFetch() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }

  let directory = try temporaryConsumer()
  try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
  try writeMakeFile(directory, "Package.swift", "// warm\n")
  try writeMakeFile(directory, "scripts/swift-mk-build.sh", "#!/usr/bin/env bash\nexit 0\n")
  // A file outside the three assets assets_complete checks, so a partial swap
  // that happened to keep only those three would still be caught here.
  try writeMakeFile(directory, "scripts/swift-mk-fetch-one.sh", "#!/usr/bin/env bash\nexit 0\n")

  // Deny write access to the consumer root itself, so the helper cannot
  // create the staging directory it needs before it may touch .make. This is
  // a real, unmocked failure (EACCES), not an injected one.
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o555], ofItemAtPath: directory)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
  }

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status != 0)

  #expect(readMakeFile(directory, "swift.mk") == "# warm swift.mk\n")
  #expect(readMakeFile(directory, "Package.swift") == "// warm\n")
  #expect(readMakeFile(directory, "scripts/swift-mk-fetch-one.sh") != nil)

  // Restore write access and prove the untouched warm tree is still complete:
  // the earlier failure never left .make half swapped.
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
  let skipFetchResult = runHelper(
    directory: directory,
    environment: [
      "SWIFT_MK_CODELOAD_BASE": server.codeloadBase, "SWIFT_MK_SKIP_FETCH": "1",
    ])
  #expect(skipFetchResult.status == 0, "skip-fetch failed: \(skipFetchResult.stderr)")
}

@Test
func helperFailsWhenPreservingAGeneratedFileCannotBeCopied() throws {
  // `if provision; then` puts everything provision calls in bash's -e ignore
  // list, so a step inside install_from_stage that fails without an explicit
  // check would be silently ignored rather than aborting. Forwarding a
  // preserved runtime file that cannot be read is exactly such a step: it
  // must fail loudly instead of quietly dropping the file from the new .make.
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }

  let directory = try temporaryConsumer()
  try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
  try writeMakeFile(directory, "Package.swift", "// warm\n")
  try writeMakeFile(directory, "scripts/swift-mk-build.sh", "#!/usr/bin/env bash\nexit 0\n")
  try writeMakeFile(directory, "build.lock", "warm lock\n")
  let lockPath = makePath(directory, "build.lock")
  try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockPath)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockPath)
  }

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status != 0)

  // The install must abort rather than silently swap in a tree that dropped
  // build.lock; the original warm tree, unreadable file included, survives.
  #expect(readMakeFile(directory, "swift.mk") == "# warm swift.mk\n")
  #expect(readMakeFile(directory, "Package.swift") == "// warm\n")
}

@Test
func helperSkipFetchRejectsARequiredAssetThatIsActuallyADirectory() throws {
  // assets_complete's old check, `-s` alone, is true for a non-empty
  // directory as well as a regular file, so a required asset path that is
  // actually a directory would have been accepted as complete.
  let directory = try temporaryConsumer()
  try writeMakeFile(directory, "swift.mk", "# warm swift.mk\n")
  try writeMakeFile(directory, "Package.swift", "// warm\n")
  try writeMakeFile(directory, "scripts/swift-mk-build.sh/placeholder", "not a script\n")

  let result = runHelper(
    directory: directory,
    environment: ["SWIFT_MK_CODELOAD_BASE": "http://127.0.0.1:9", "SWIFT_MK_SKIP_FETCH": "1"])
  #expect(result.status != 0)
}

func readMarker(_ directory: String) -> [String: String] {
  guard let body = readMakeFile(directory, ".swift-mk-snapshot-ref") else {
    return [:]
  }
  var fields: [String: String] = [:]
  for line in body.split(separator: "\n") {
    let parts = line.split(separator: "=", maxSplits: 1)
    if parts.count == 2 {
      fields[String(parts[0])] = String(parts[1])
    }
  }
  return fields
}

func writeMarker(_ directory: String, ref: String, etag: String, timestamp: Int) throws {
  try writeMakeFile(
    directory, ".swift-mk-snapshot-ref", "ref=\(ref)\netag=\(etag)\ntimestamp=\(timestamp)\n")
}

/// Populates .make with a complete engine tree so only the validation decision
/// is under test.
func warmSnapshot(_ directory: String) throws {
  for (name, body) in engineFiles() where name != "scripts/swift-mk-bootstrap.sh" {
    try writeMakeFile(directory, name, body)
  }
}

@Test
func helperRecordsMarkerWithEtagOnColdProvision() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status == 0, "\(result.stderr)")

  let marker = readMarker(directory)
  #expect(marker["ref"] == "main")
  #expect(marker["etag"]?.isEmpty == false)
  #expect(Int(marker["timestamp"] ?? "") != nil)
}

@Test
func helperTouchesNothingWhenUpstreamReturnsNotModified() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()

  #expect(
    runHelper(directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
      .status == 0)

  let path = makePath(directory, "swift.mk")
  let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
  // A 304 must not re-extract, so the mtime must not move. Sleep past the
  // filesystem timestamp granularity so a re-extract would be detectable.
  Thread.sleep(forTimeInterval: 1.1)

  let second = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(second.status == 0, "\(second.stderr)")

  let after = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
  #expect(before == after, "a 304 re-extracted the tree and moved mtimes")

  let requests = server.requests()
  #expect(requests.count == 2)
  #expect(requests[1].status == 304)
  #expect(requests[1].bytes == 0)
}

@Test
func helperUnfreezesAMarkerThatHoldsOnlyARefName() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()
  try warmSnapshot(directory)
  // The format the current engine writes: a bare ref name, no ETag.
  try writeMakeFile(directory, ".swift-mk-snapshot-ref", "main\n")

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status == 0, "\(result.stderr)")

  #expect(server.requests().count == 1)
  #expect(server.requests()[0].status == 200, "a bare-ref marker must force a real fetch")
  #expect(readMarker(directory)["etag"]?.isEmpty == false)
}

@Test
func helperServesSnapshotWhenUpstreamStallsAndMarkerIsRecent() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()
  try warmSnapshot(directory)
  try writeMarker(
    directory, ref: "main", etag: "\"cached\"", timestamp: Int(Date().timeIntervalSince1970) - 600)
  server.stall(5)

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status == 0, "\(result.stderr)")
  #expect(result.stderr.contains("serving the .make snapshot validated"))
  #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v1\n")
}

@Test
func helperFailsWhenUpstreamStallsAndMarkerIsStale() throws {
  // The validation request stalls past its own 3 second budget and times out,
  // but a stale marker forces a real provision attempt next, so the upstream
  // also has to genuinely fail that second request (a real 500, not just a
  // slow response) for the whole run to fail. Without forceStatus(500) here,
  // the forced provision would stall the same 5 seconds and then succeed,
  // since its budget is 60 seconds; see
  // helperForceProvisionsWhenValidationTimesOutAndMarkerIsStale for that case.
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()
  try warmSnapshot(directory)
  try writeMarker(
    directory, ref: "main", etag: "\"cached\"", timestamp: Int(Date().timeIntervalSince1970) - 7200)
  server.stall(5)
  server.forceStatus(500)

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status != 0)
  #expect(!result.stderr.contains("serving the .make snapshot validated"))
  // Nothing may be destroyed even on the failing path.
  #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v1\n")
}

@Test
func helperForceProvisionsWhenValidationTimesOutAndMarkerIsStale() throws {
  // Regression guard: a validation timeout only proves the cheap 3 second
  // check did not finish, not that the network is down. A stale marker must
  // still force a real provision attempt with its own 60 second budget, and
  // that attempt can succeed even though validation did not.
  var updatedFiles = engineFiles()
  updatedFiles["swift.mk"] = "# swift.mk v2\n"
  let server = try FetchServer(files: updatedFiles)
  defer { server.shutdown() }
  let directory = try temporaryConsumer()
  try warmSnapshot(directory)
  try writeMarker(
    directory, ref: "main", etag: "\"cached\"", timestamp: Int(Date().timeIntervalSince1970) - 7200)
  server.stall(5)

  let result = runHelper(
    directory: directory, environment: ["SWIFT_MK_CODELOAD_BASE": server.codeloadBase])
  #expect(result.status == 0, "\(result.stderr)")
  #expect(!result.stderr.contains("serving the .make snapshot validated"))
  // The forced provision reached the upstream and installed its current
  // content, not the stale warm tree the marker described.
  #expect(readMakeFile(directory, "swift.mk") == "# swift.mk v2\n")
}

@Test
func helperProvisionsUnconditionallyInCI() throws {
  let server = try FetchServer(files: engineFiles())
  defer { server.shutdown() }
  let directory = try temporaryConsumer()
  try warmSnapshot(directory)
  try writeMarker(
    directory, ref: "main", etag: "\"cached\"", timestamp: Int(Date().timeIntervalSince1970))

  let result = runHelper(
    directory: directory,
    environment: [
      "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
      "GITHUB_ACTIONS": "true",
      "GITHUB_RUN_ID": "1",
    ])
  #expect(result.status == 0, "\(result.stderr)")
  #expect(server.requests().count == 1)
  #expect(server.requests()[0].ifNoneMatch.isEmpty, "CI sent a conditional request")
  #expect(server.requests()[0].status == 200)
}
