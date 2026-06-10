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

// The errorLines string filter was deleted: build-failure diagnosis now decodes
// the xcresult bundle (XCResultTests cover the mapping) and the transcript is a
// saved artifact that nothing parses.
