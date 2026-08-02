//
//  FetchTestSupport.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-29.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - FetchTestSupport

/// Fixtures and helpers the fetch, bootstrap, and snapshot suites all share.
///
/// They live here rather than beside any one suite because they are used across
/// several: `engineFiles` alone is needed by the server tests, the helper tests,
/// and the snapshot tests, so keeping it in one suite's file made that file the
/// implicit owner of everything downstream.
enum FetchTestSupport {}

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
  do {
    return try String(contentsOfFile: makePath(directory, relative), encoding: .utf8)
  } catch {
    // Absent is a real answer: several assertions check that a file the helper
    // should not have written is missing.
    return nil
  }
}

/// Restores permissions a test tightened to force a real EACCES, so the temp tree
/// can be cleaned up afterward. Reported rather than dropped, because a failure
/// here leaves an undeletable directory behind.
func restorePermissions(_ mode: Int, atPath path: String) {
  do {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
  } catch {
    Output.warning("test: could not restore permissions on \(path): \(error)")
  }
}

/// Run the bootstrap helper. See `BootstrapHelperRunner` for why the wait happens on a
/// thread of its own.
func runHelper(
  directory: String,
  environment: [String: String]
) async -> BootstrapHelperRunner.Result {
  await BootstrapHelperRunner.run(directory: directory, environment: environment)
}

/// Permission bits the tests set to force a genuine failure and then restore.
let writableDirectoryMode = 0o755
let readOnlyDirectoryMode = 0o555
let writableFileMode = 0o644
let unreadableFileMode = 0o000

/// A marker line is `key=value`, so a usable split yields exactly two parts.
let markerKeyValuePartCount = 2

/// Above the helper's own 1024 B/s floor, so the transfer keeps making visible
/// progress and the progress-based abort correctly leaves it alone.
let slowButProgressingRate = 2_048

/// A marker just written, which the helper reads as current.
let freshMarkerAge = 0
/// A marker old enough to be worth validating, young enough to still serve from disk.
let recentMarkerAge = 600
/// A marker old enough that the helper must force a real provision.
let staleMarkerAge = 7_200
/// Longer than the filesystem's one-second timestamp granularity, so a rewrite that did
/// happen is detectable.
let pastTimestampGranularityMilliseconds = 1_100
/// How many requests a cold provision followed by one validation makes.
let coldThenValidateRequestCount = 2
/// The status a matching conditional request gets back.
let notModifiedStatus = 304
