//
//  MaintenanceOutputTests.swift
//  SwiftMkMaintCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkMaintCore

// MARK: - MaintenanceOutputTests

enum MaintenanceOutputTests {
  @Test
  static func logAndLogErrorWriteSingleLinesToTheSelectedStreams() {
    var standardOutput: [String] = []
    var standardError: [String] = []
    let output = MaintenanceOutput(
      standardOutput: { text in standardOutput.append(text) },
      standardError: { text in standardError.append(text) })

    output.log("hello")
    output.logError("problem")

    #expect(standardOutput == ["hello\n"])
    #expect(standardError == ["problem\n"])
  }

  @Test
  static func infoStaysSilentUntilTheEnvironmentSelectsInfoLogging() {
    var standardError: [String] = []
    let quietOutput = MaintenanceOutput(
      standardOutput: { text in _ = text },
      standardError: { text in standardError.append(text) },
      environment: { [:] })
    let verboseOutput = MaintenanceOutput(
      standardOutput: { text in _ = text },
      standardError: { text in standardError.append(text) },
      environment: { ["SWIFT_MK_LOG_LEVEL": "info"] })

    quietOutput.info("hidden")
    verboseOutput.info("visible")

    #expect(standardError == ["visible\n"])
  }
}
