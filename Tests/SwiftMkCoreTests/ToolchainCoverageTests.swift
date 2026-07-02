//
//  ToolchainCoverageTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - ToolchainCoverageTests

@Suite(.serialized)
enum ToolchainCoverageTests {
  @Test
  static func coverageDestinationMapsEveryKnownPlatform() {
    #expect(Toolchain.coverageDestination(for: .macosx) == "platform=macOS")
    #expect(
      Toolchain.coverageDestination(for: .iphonesimulator)
        == "generic/platform=iOS Simulator")
    #expect(
      Toolchain.coverageDestination(for: .maccatalyst)
        == "generic/platform=macOS,variant=Mac Catalyst")
  }

  @Test
  static func coverageDestinationIsNonEmptyForEveryCoveragePlatform() {
    for platform in CoveragePlatform.allCases {
      #expect(!Toolchain.coverageDestination(for: platform).isEmpty)
    }
  }
}
