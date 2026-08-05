//
//  BootstrapHelperRunner.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation

@testable import SwiftMkCore

// MARK: - BootstrapHelperRunner

/// Runs `scripts/swift-mk-bootstrap.sh` for the fetch tests, off the cooperative pool.
enum BootstrapHelperRunner {
  /// What one helper run produced.
  struct Result {
    let stdout: String
    let stderr: String
    let status: Int32
  }

  /// The repository this test file lives in, so the helper under test is the one in the
  /// checkout rather than one a consumer fetched.
  static func repositoryRoot() -> String {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .path
  }

  /// Run the helper with the working directory at `directory` and an environment that
  /// never inherits a real continuous-integration context.
  ///
  /// The run waits for a subprocess, so it happens on a thread of its own rather than on
  /// the cooperative thread the test body occupies; see `OffPoolWork`.
  static func run(directory: String, environment: [String: String]) async -> Result {
    let merged = mergedEnvironment(environment)
    return await OffPoolWork.run {
      runBlocking(directory: directory, environment: merged)
    }
  }

  /// The helper's environment, with `environment` layered over the defaults.
  static func mergedEnvironment(_ environment: [String: String]) -> [String: String] {
    // Reading ProcessInfo.processInfo.environment enumerates the process-wide libc
    // environ table. Several other suites in this target call setenv/unsetenv
    // (see TestGlobalLock in GatedBuildHarness.swift), and Swift Testing runs
    // suites in parallel within this one process, so an unsynchronized read here
    // can race a concurrent setenv and observe a corrupted or partially-freed
    // PATH/HOME value. TestGlobalLock is the same lock those setenv call sites
    // already hold, so this read is now serialized against them.
    var merged: [String: String] = TestGlobalLock.withLock {
      [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "",
        "SWIFT_MK_API_REPO": "agoodkind/swift-makefile",
        "SWIFT_MK_API_REF": "main",
        "SWIFT_MK_DEV_DIR": "",
        "SWIFT_MK_MODULES": "",
        "GITHUB_ACTIONS": "",
        "GITHUB_RUN_ID": "",
      ]
    }
    for (key, value) in environment {
      merged[key] = value
    }
    return merged
  }

  /// Spawn the helper and wait for it. Blocking, so only `run` calls it, and only from a
  /// thread that is not one of the cooperative pool's.
  static func runBlocking(directory: String, environment: [String: String]) -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [repositoryRoot() + "/scripts/swift-mk-bootstrap.sh"]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    process.environment = environment
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
      try process.run()
    } catch {
      // A spawn that never started has no exit status of its own, so report the
      // launch failure rather than letting it read as a helper failure.
      return Result(
        stdout: "",
        stderr: "test: could not launch the bootstrap helper: \(error)",
        status: -1
      )
    }
    // Drain both pipes concurrently. A pipe's kernel buffer is bounded (about
    // 64 KB), so reading stdout to end of file before touching stderr deadlocks
    // when the helper fills stderr first: the helper blocks in write() while
    // this thread blocks in read() on a stream that cannot reach end of file
    // until the helper exits. A dedicated thread for stderr keeps both moving.
    let stderrBox = DrainBox()
    let stderrThread = Thread {
      stderrBox.store(errPipe.fileHandleForReading.readDataToEndOfFile())
    }
    stderrThread.start()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = stderrBox.waitForData()
    process.waitUntilExit()
    return Result(
      stdout: Output.decodeCapturedUTF8(outData),
      stderr: Output.decodeCapturedUTF8(errData),
      status: process.terminationStatus
    )
  }

  /// Hands one drained pipe's bytes from its reader thread back to the caller.
  /// A condition-signalled box rather than a bare variable, so the caller
  /// blocks until the reader has genuinely finished instead of racing it.
  private final class DrainBox: @unchecked Sendable {
    private let condition = NSCondition()
    private var data: Data?

    func store(_ drained: Data) {
      condition.lock()
      data = drained
      condition.signal()
      condition.unlock()
    }

    func waitForData() -> Data {
      condition.lock()
      while data == nil {
        condition.wait()
      }
      let drained = data ?? Data()
      condition.unlock()
      return drained
    }
  }

  /// Run `chflags` on `path` and return its exit status, or a non-zero stand-in when it
  /// cannot start. Names its own working directory, because a child that inherits the
  /// process one can land on a directory another suite is deleting.
  static func chflagsStatus(_ flag: String, _ path: String) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
    process.arguments = [flag, path]
    process.currentDirectoryURL = URL(
      fileURLWithPath: (path as NSString).deletingLastPathComponent)
    do {
      try process.run()
    } catch {
      Output.error("test: chflags \(flag) \(path) failed to start: \(error)")
      return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
  }
}
