//
//  ShellTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ShellTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `ShellTests.swift`; the suite is written as free `@Test` functions.
enum ShellTests {}

/// `dd` writing to `/dev/stderr` floods one stream past the pipe buffer from a
/// single process, with no shell and no pipeline. `status=none` suppresses dd's
/// own summary so the byte count is exact. The earlier capture drained stdout to
/// EOF before reading stderr and deadlocked here; the concurrent drain returns.
/// The time limit fails the test rather than hanging the suite if it regresses.
private let largeByteCount = 204_800

@Test(.timeLimit(.minutes(1)))
func shellRunCapturesLargeStderrWithoutDeadlock() {
  let result = Shell.run(
    "dd",
    ["if=/dev/zero", "of=/dev/stderr", "bs=1024", "count=200", "status=none"])
  #expect(result.status == 0)
  #expect(result.stdout.isEmpty)
  #expect(result.stderr.utf8.count == largeByteCount)
}

/// The same flood directed at stdout confirms the other stream is drained in full
/// too, so the fix is not specific to whichever stream was read second.
@Test(.timeLimit(.minutes(1)))
func shellRunCapturesLargeStdoutWithoutDeadlock() {
  let result = Shell.run(
    "dd",
    ["if=/dev/zero", "of=/dev/stdout", "bs=1024", "count=200", "status=none"])
  #expect(result.status == 0)
  #expect(result.stderr.isEmpty)
  #expect(result.stdout.utf8.count == largeByteCount)
}

/// Small captures keep the existing contract: exact bytes on the right stream and
/// `combined` as stdout followed by stderr.
@Test
func shellRunSeparatesSmallStdoutAndStderr() {
  let result = Shell.run("printf", ["hello"])
  #expect(result.status == 0)
  #expect(result.stdout == "hello")
  #expect(result.stderr.isEmpty)
  #expect(result.combined == "hello")
}
