//
//  ShellStreamingTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

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
