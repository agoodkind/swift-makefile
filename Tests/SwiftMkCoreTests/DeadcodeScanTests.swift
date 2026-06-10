//
//  DeadcodeScanTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - DeadcodeScanTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `DeadcodeScanTests.swift`; the suite is written as free `@Test` functions.
enum DeadcodeScanTests {}

@Test
func xcodeScanRunsOnlyForConfiguredXcodeBuild() {
  // The Xcode dead-code scan runs only when the consumer configures an Xcode build
  // (SWIFT_MK_XCODE_BUILD == "1"). A SwiftPM repo (empty flag) is covered by
  // periphery's package scan, so a stray on-disk .xcodeproj must not force a scan.
  #expect(DeadcodeScan.xcodeScanEnabled("1"))
  #expect(!DeadcodeScan.xcodeScanEnabled(""))
  #expect(!DeadcodeScan.xcodeScanEnabled("0"))
}

@Test
func errorLinesCaptureFailingCommandListWithoutCompilerErrors() {
  // A build can fail with no `error:` line (a script phase, a signing step), so
  // the failing-command list xcodebuild prints after the summary header is the
  // only text naming the cause and must survive the filter.
  let output = [
    "CompileSwift normal arm64 (in target 'FanCurve' from project 'FanCurveApp')",
    "** BUILD FAILED **",
    "",
    "The following build commands failed:",
    "\tPhaseScriptExecution Generate\\ Config (in target 'FanCurve')",
    "\tCodeSign /tmp/Fan\\ Curve.app (in target 'FanCurve')",
    "(2 failures)",
    "trailing noise that must not be captured",
  ].joined(separator: "\n")

  let lines = BuildFailureLog.errorLines(in: output)

  #expect(
    lines == [
      "** BUILD FAILED **",
      "The following build commands failed:",
      "\tPhaseScriptExecution Generate\\ Config (in target 'FanCurve')",
      "\tCodeSign /tmp/Fan\\ Curve.app (in target 'FanCurve')",
      "(2 failures)",
    ])
}

@Test
func errorLinesKeepCompilerErrorsInSourceOrder() {
  let output = [
    "Sources/App.swift:10:5: error: cannot find 'foo' in scope",
    "ordinary build chatter",
    "** BUILD FAILED **",
  ].joined(separator: "\n")

  let lines = BuildFailureLog.errorLines(in: output)

  #expect(
    lines == [
      "Sources/App.swift:10:5: error: cannot find 'foo' in scope",
      "** BUILD FAILED **",
    ])
}
