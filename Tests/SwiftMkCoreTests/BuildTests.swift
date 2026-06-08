//
//  BuildTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-07.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BuildTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `BuildTests.swift`; the suite is written as free `@Test` functions.
enum BuildTests {}

@Test
func buildGatesForSwiftPMConsumerOnly() {
  // A SwiftPM consumer has no SWIFT_XCODE_SCHEME, so swift-mk build is the gating
  // chokepoint. An Xcode consumer routes through `swift-mk toolchain build`, which
  // gates itself, so swift-mk build must not gate again.
  #expect(Build.shouldGate(xcodeScheme: ""))
  #expect(Build.shouldGate(xcodeScheme: "   "))
  #expect(!Build.shouldGate(xcodeScheme: "App"))
}
