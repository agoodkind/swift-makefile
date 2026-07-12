//
//  ShellForwardingCaptureTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-11.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ShellForwardingCaptureTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching the
/// file; the tests are written as free `@Test` functions.
enum ShellForwardingCaptureTests {}

@Test
func forwardingAndCapturingReturnsBothStreamsAndStatus() {
  let result = Shell.runForwardingAndCapturing(
    "/bin/sh", ["-c", "printf out; printf err 1>&2; exit 3"])
  #expect(result.status == 3)
  #expect(result.stdout == "out")
  #expect(result.stderr == "err")
  #expect(result.combined == "outerr")
}

@Test
func forwardingAndCapturingReturnsZeroStatusOnSuccess() {
  let result = Shell.runForwardingAndCapturing("/bin/sh", ["-c", "printf done"])
  #expect(result.status == 0)
  #expect(result.combined == "done")
}
