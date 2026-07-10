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

// MARK: - ShellEnvironmentTests

extension EnvironmentSerialized {
  @Suite enum ShellEnvironmentTests {
    private static let traceKeys = [
      "TRACEPARENT", "TRACE_ID", "SPAN_ID", "SWIFT_MK_TRACE_ID", "SWIFT_MK_SPAN_ID",
    ]

    @Test
    static func runWithOverridesInheritsLiveTraceEnvironment() {
      let saved = savedTraceEnvironment()
      _ = ProcessInfo.processInfo.environment
      setenv("TRACEPARENT", "00-11111111111111111111111111111111-2222222222222222-01", 1)
      setenv("TRACE_ID", "11111111111111111111111111111111", 1)
      setenv("SPAN_ID", "2222222222222222", 1)
      setenv("SWIFT_MK_TRACE_ID", "11111111111111111111111111111111", 1)
      setenv("SWIFT_MK_SPAN_ID", "2222222222222222", 1)
      defer {
        restoreTraceEnvironment(saved)
      }

      let result = Shell.run(
        "/usr/bin/env",
        environment: [
          "SPAN_ID": "stale",
          "SWIFT_MK_SPAN_ID": "stale",
          "SWIFT_MK_TEST_OVERRIDE": "1",
          "SWIFT_MK_TRACE_ID": "stale",
          "TRACEPARENT": "stale",
          "TRACE_ID": "stale",
        ])

      #expect(result.status == 0)
      let expectedTraceparent = """
        TRACEPARENT=00-11111111111111111111111111111111-2222222222222222-01

        """
      #expect(result.stdout.contains(expectedTraceparent))
      #expect(result.stdout.contains("TRACE_ID=11111111111111111111111111111111\n"))
      #expect(result.stdout.contains("SPAN_ID=2222222222222222\n"))
      #expect(result.stdout.contains("SWIFT_MK_TRACE_ID=11111111111111111111111111111111\n"))
      #expect(result.stdout.contains("SWIFT_MK_SPAN_ID=2222222222222222\n"))
    }

    private static func savedTraceEnvironment() -> [String: String?] {
      var saved: [String: String?] = [:]
      for key in traceKeys {
        saved[key] = getenv(key).map { String(cString: $0) }
      }
      return saved
    }

    private static func restoreTraceEnvironment(_ saved: [String: String?]) {
      for key in traceKeys {
        guard let savedValue = saved[key] else {
          unsetenv(key)
          continue
        }
        guard let value = savedValue else {
          unsetenv(key)
          continue
        }
        setenv(key, value, 1)
      }
    }
  }
}
