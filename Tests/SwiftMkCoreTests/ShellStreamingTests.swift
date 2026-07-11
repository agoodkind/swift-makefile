//
//  ShellStreamingTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Darwin
import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ShellStreamingTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `ShellStreamingTests.swift`; the suite is written as free `@Test` functions.
enum ShellStreamingTests {}

@Test
func shellRunStreamingStderrCapturesStdout() {
  let result = Shell.runStreamingStderr("/bin/sh", ["-c", "printf hello"])
  #expect(result.status == 0)
  #expect(result.stdout == "hello")
  #expect(!result.timedOut)
}

@Test
func shellRunStreamingStderrLeavesStderrOutOfStdout() {
  let result = Shell.runStreamingStderr("/bin/sh", ["-c", "printf oops 1>&2; exit 3"])
  #expect(result.status == 3)
  #expect(result.stdout.isEmpty)
  #expect(!result.timedOut)
}

@Test(.timeLimit(.minutes(1)))
func shellRunStreamingStderrTimesOut() {
  let startedAt = Date()
  let result = Shell.runStreamingStderr(
    "/bin/sh",
    ["-c", "while :; do :; done"],
    timeoutSeconds: 0.5)
  let elapsedSeconds = Date().timeIntervalSince(startedAt)

  #expect(result.timedOut)
  #expect(result.status != 0)
  #expect(elapsedSeconds < 3)
}

@Test(.timeLimit(.minutes(1)))
func shellRunStreamingStderrReapsProcessTreeOnTimeout() throws {
  let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-shell-timeout-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: temporaryDirectory, withIntermediateDirectories: true)

  let parentPIDURL = temporaryDirectory.appendingPathComponent("parent.pid")
  let childPIDURL = temporaryDirectory.appendingPathComponent("child.pid")
  var recordedPIDs: [pid_t] = []
  defer {
    for pid in recordedPIDs {
      _ = kill(pid, SIGKILL)
    }
    try? FileManager.default.removeItem(at: temporaryDirectory)
  }

  let script = """
    printf '%s' "$$" > "\(parentPIDURL.path)"
    /bin/sh -c 'trap "" HUP TERM; printf '\''%s'\'' "$$" > "\(childPIDURL.path)"; while :; do :; done' \
      </dev/null >/dev/null 2>&1 &
    while :; do :; done
    """
  let result = Shell.runStreamingStderr(
    "/bin/sh", ["-c", script], timeoutSeconds: 0.5)

  #expect(result.timedOut)
  recordedPIDs = try [parentPIDURL, childPIDURL].map { url in
    let value = try String(contentsOf: url, encoding: .utf8)
    return try #require(pid_t(value))
  }
  for pid in recordedPIDs {
    #expect(processIsDead(pid, timeoutSeconds: 2))
  }
}

private func processIsDead(_ pid: pid_t, timeoutSeconds: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeoutSeconds)
  repeat {
    errno = 0
    if kill(pid, 0) == -1, errno == ESRCH {
      return true
    }
    usleep(10_000)
  } while Date() < deadline
  return false
}
