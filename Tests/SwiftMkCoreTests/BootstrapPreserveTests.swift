//
//  BootstrapPreserveTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-29.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BootstrapPreserveTests

enum BootstrapPreserveTests {}

@Test
func helperFailsWhenTheRuntimeFilePreserveEnumerationFails() async throws {
  // The enumeration that decides which runtime files survive the swap used to be
  // read straight from a process substitution, whose exit status the reading loop
  // cannot see. A failing `find` therefore yielded an empty list rather than an
  // error, every preserved file was silently skipped, and the swap replaced .make
  // without them while the run still exited 0. The file that matters most there
  // is build.lock: losing it mid-build leaves the running build holding the old
  // inode while the next build creates and locks a new one, so the per-worktree
  // lock stops serializing anything.
  //
  // `find` is shadowed only for the preserve enumeration, which is the one call
  // that passes -mindepth; every other use passes through to the real tool, so
  // this drives the exact step under test rather than breaking the whole run.
  try await FetchServer.withServer(files: engineFiles()) { server in
    let directory = try temporaryConsumer()
    try warmSnapshot(directory)
    try writeMakeFile(directory, "build.lock", "live lock\n")

    let fakeBin = (directory as NSString).appendingPathComponent("fakebin")
    try FileManager.default.createDirectory(
      atPath: fakeBin, withIntermediateDirectories: true)
    let findShim = """
      #!/bin/sh
      for argument in "$@"; do
        if [ "$argument" = "-mindepth" ]; then
          exit 1
        fi
      done
      exec /usr/bin/find "$@"
      """
    let findPath = (fakeBin as NSString).appendingPathComponent("find")
    try findShim.write(toFile: findPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: findPath)

    let inheritedPath = TestGlobalLock.withLock {
      ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    }
    let result = await runHelper(
      directory: directory,
      environment: [
        "SWIFT_MK_CODELOAD_BASE": server.codeloadBase,
        "PATH": fakeBin + ":" + inheritedPath,
      ]
    )

    #expect(
      result.status != 0,
      "a failed preserve enumeration must fail the provision, not silently drop files")
    #expect(
      readMakeFile(directory, "build.lock") == "live lock\n",
      "build.lock must survive a provision that could not enumerate what to preserve")
  }
}
